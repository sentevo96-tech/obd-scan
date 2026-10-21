import Foundation
import Combine

enum OBDError: LocalizedError {
    case notConnected, timeout, noData, unableToConnect
    case adapter(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Адаптер не подключён"
        case .timeout: return "Адаптер не ответил вовремя"
        case .noData: return "Нет данных от автомобиля"
        case .unableToConnect: return "Не удалось связаться с ЭБУ. Включите зажигание и попробуйте снова"
        case .adapter(let s): return "Ошибка адаптера: \(s)"
        }
    }
}

struct LiveData {
    var rpm: Double?
    var speed: Double?
    var coolant: Double?
    var intakeTemp: Double?
    var throttle: Double?
    var load: Double?
}

@MainActor
final class OBDService: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var status = ""
    @Published private(set) var live = LiveData()
    @Published private(set) var stored: [String] = []
    @Published private(set) var pending: [String] = []
    @Published private(set) var milOn: Bool?
    @Published var lastError: String?

    private let transport: BLETransport
    private var isCAN = true
    private var pollTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init(transport: BLETransport) {
        self.transport = transport
        transport.$isConnected
            .dropFirst()
            .sink { [weak self] connected in
                Task { @MainActor in self?.handleConnection(connected) }
            }
            .store(in: &bag)
    }

    private func handleConnection(_ connected: Bool) {
        guard !connected else { return }
        isReady = false
        live = LiveData()
        Task { await stopPolling() }
    }

    func disconnect() { transport.disconnect() }

    // MARK: - Инициализация ELM327

    func setup() async throws {
        isReady = false
        status = "Инициализация адаптера…"
        _ = try await transport.send("ATZ", timeout: 4)
        // E0 — без эха, L0 — без переводов строки, S0 — без пробелов, H0 — без заголовков, SP0 — авто-протокол
        for cmd in ["ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"] {
            _ = try await transport.send(cmd)
        }

        status = "Поиск протокола автомобиля…"
        let r = try await query("0100", timeout: 20)
        guard r.contains(where: { $0.hasPrefix("4100") }) else { throw OBDError.noData }

        // Номер протокола: 6–9 = CAN (формат ответа на команды 03/07 у CAN отличается)
        if let dp = (try? await query("ATDPN"))?.first {
            var s = dp
            if s.hasPrefix("A"), s.count == 2 { s.removeFirst() }
            isCAN = (Int(s, radix: 16) ?? 6) >= 6
        }

        status = "Подключено"
        isReady = true
    }

    // MARK: - Живые данные

    func startPolling() {
        guard isReady, pollTask == nil else { return }
        pollTask = Task { await pollLoop() }
    }

    func stopPolling() async {
        let t = pollTask
        pollTask = nil
        t?.cancel()
        await t?.value
    }

    private func pollLoop() async {
        while !Task.isCancelled, transport.isConnected {
            var d = live
            if let b = try? await pid(0x0C), b.count >= 2 { d.rpm = (Double(b[0]) * 256 + Double(b[1])) / 4 }
            if let b = try? await pid(0x0D), b.count >= 1 { d.speed = Double(b[0]) }
            if let b = try? await pid(0x05), b.count >= 1 { d.coolant = Double(b[0]) - 40 }
            if let b = try? await pid(0x0F), b.count >= 1 { d.intakeTemp = Double(b[0]) - 40 }
            if let b = try? await pid(0x11), b.count >= 1 { d.throttle = Double(b[0]) * 100 / 255 }
            if let b = try? await pid(0x04), b.count >= 1 { d.load = Double(b[0]) * 100 / 255 }
            live = d
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Коды ошибок

    func readDTCs() async {
        lastError = nil
        do {
            if let b = try? await pid(0x01), let first = b.first { milOn = (first & 0x80) != 0 }
            stored = try await fetchCodes(request: "03", response: 0x43)   // сохранённые
            pending = try await fetchCodes(request: "07", response: 0x47)  // ожидающие
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearDTCs() async {
        lastError = nil
        do {
            let lines = try await query("04", timeout: 10)
            guard lines.contains(where: { $0.hasPrefix("44") }) else {
                throw OBDError.adapter("ЭБУ не подтвердил сброс. Обычно нужно включить зажигание и заглушить двигатель")
            }
            await readDTCs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchCodes(request: String, response: UInt8) async throws -> [String] {
        let lines: [String]
        do { lines = try await query(request, timeout: 10) }
        catch OBDError.noData { return [] }   // часть ЭБУ отвечает NO DATA, если ошибок нет

        // Длинные CAN-ответы приходят как "0:…", "1:…"; короткие — одной строкой на каждый ЭБУ
        var payloads: [[UInt8]]
        if lines.contains(where: { $0.contains(":") }) {
            let joined = lines.filter { $0.contains(":") }.flatMap { line -> [UInt8] in
                bytes(String(line.split(separator: ":", maxSplits: 1).last ?? ""))
            }
            payloads = [joined]
        } else {
            payloads = lines.map { bytes($0) }
        }

        var out = Set<String>()
        for p in payloads where p.first == response {
            let body = Array(p.dropFirst())
            if isCAN {
                // CAN: [43][кол-во кодов][пары байт…]
                guard let count = body.first else { continue }
                let codes = Array(body.dropFirst())
                for i in 0..<Int(count) where i * 2 + 1 < codes.count {
                    out.insert(Self.decode(codes[i * 2], codes[i * 2 + 1]))
                }
            } else {
                // J1850 / ISO 9141 / KWP: [43][до 3 пар байт], пустые пары = 0000
                for i in stride(from: 0, to: body.count - 1, by: 2) where !(body[i] == 0 && body[i + 1] == 0) {
                    out.insert(Self.decode(body[i], body[i + 1]))
                }
            }
        }
        return out.sorted()
    }

    /// Два байта → код вида P0133 / C0035 / B1000 / U0100
    private static func decode(_ a: UInt8, _ b: UInt8) -> String {
        let letters = ["P", "C", "B", "U"]
        let letter = letters[Int(a >> 6)]
        let digit = (a >> 4) & 0x03
        return letter + String(digit) + String(format: "%X%02X", a & 0x0F, b)
    }

    // MARK: - Низкий уровень

    /// Отправляет команду, чистит ответ и превращает ошибки адаптера в OBDError.
    private func query(_ cmd: String, timeout: TimeInterval = 5) async throws -> [String] {
        let raw = try await transport.send(cmd, timeout: timeout)
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ">", with: "") }
            .filter { !$0.isEmpty }

        if lines.contains(where: { $0.contains("UNABLETOCONNECT") }) { throw OBDError.unableToConnect }
        if lines.contains("NODATA") { throw OBDError.noData }
        if let bad = lines.first(where: { $0 == "?" || $0.contains("ERROR") || $0 == "STOPPED" }) {
            throw OBDError.adapter(bad)
        }
        return lines.filter { !$0.hasPrefix("SEARCHING") && !$0.hasPrefix("BUSINIT") }
    }

    /// Mode 01: возвращает байты данных PID (без 41 и номера PID)
    private func pid(_ id: UInt8) async throws -> [UInt8] {
        let lines = try await query(String(format: "01%02X", id))
        for l in lines {
            let b = bytes(l)
            if b.count >= 3, b[0] == 0x41, b[1] == id { return Array(b.dropFirst(2)) }
        }
        throw OBDError.noData
    }

    private func bytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() {
            if let v = UInt8(String([a, b]), radix: 16) { out.append(v) }
        }
        return out
    }
}
