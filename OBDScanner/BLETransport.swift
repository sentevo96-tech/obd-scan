import Foundation
@preconcurrency import CoreBluetooth

struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// BLE-транспорт для адаптеров ELM327.
/// У разных клонов разные UUID сервисов (FFF0, FFE0, 18F0 ...), поэтому write/notify-характеристики
/// определяются автоматически. Метод send() отправляет команду и ждёт ответ до приглашения ">".
@MainActor
final class BLETransport: NSObject, ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var bluetoothReady = false

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var buffer = ""
    private var pending: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Поиск и подключение

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        peripherals.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil)
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredDevice) async throws {
        guard let p = peripherals[device.id] else { throw OBDError.notConnected }
        stopScan()
        peripheral = p
        p.delegate = self
        writeChar = nil
        notifyChar = nil

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectContinuation = c
            central.connect(p)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.connectContinuation != nil else { return }
                self.failConnect(OBDError.timeout)
            }
        }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    private func failConnect(_ error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }

    private func finishConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    // MARK: - Обмен командами

    func send(_ command: String, timeout: TimeInterval = 5) async throws -> String {
        // Команды выполняются строго по одной
        while pending != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        guard isConnected, let p = peripheral, let w = writeChar else { throw OBDError.notConnected }

        buffer = ""
        let data = Data((command + "\r").utf8)
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            pending = c
            p.writeValue(data, for: w, type: type)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resolve(.failure(OBDError.timeout))
            }
        }
    }

    private func resolve(_ result: Result<String, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let c = pending else { return }
        pending = nil
        c.resume(with: result)
    }
}

// MARK: - CoreBluetooth delegates (очередь делегата = main, поэтому assumeIsolated безопасен)

extension BLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothReady = central.state == .poweredOn
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            guard let name, !name.isEmpty else { return }
            peripherals[peripheral.identifier] = peripheral
            let d = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let i = devices.firstIndex(where: { $0.id == d.id }) { devices[i] = d } else { devices.append(d) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { peripheral.discoverServices(nil) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { failConnect(error ?? OBDError.notConnected) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            isConnected = false
            writeChar = nil
            notifyChar = nil
            self.peripheral = nil
            resolve(.failure(OBDError.notConnected))
            failConnect(OBDError.notConnected)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            // Пропускаем стандартные служебные сервисы (Generic Access/Attribute, Device Information)
            let skip = ["1800", "1801", "180A"]
            guard !skip.contains(service.uuid.uuidString) else { return }

            for ch in service.characteristics ?? [] {
                if notifyChar == nil, ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    notifyChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                }
                if writeChar == nil, ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                    writeChar = ch
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic == notifyChar else { return }
            if let error { failConnect(error); return }
            if writeChar != nil {
                isConnected = true
                finishConnect()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let chunk = characteristic.value.map { String(decoding: $0, as: UTF8.self) } ?? ""
        MainActor.assumeIsolated {
            buffer += chunk
            // ELM327 заканчивает ответ символом приглашения ">"
            if buffer.contains(">") {
                let response = buffer
                buffer = ""
                resolve(.success(response))
            }
        }
    }
}
