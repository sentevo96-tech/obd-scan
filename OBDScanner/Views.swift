import SwiftUI

// MARK: - Выбор и подключение адаптера

struct ScanView: View {
    @EnvironmentObject var transport: BLETransport
    @EnvironmentObject var obd: OBDService
    @State private var connectingID: UUID?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if !transport.bluetoothReady {
                    Text("Включите Bluetooth и разрешите приложению доступ к нему")
                        .foregroundStyle(.secondary)
                }
                Section("Устройства рядом") {
                    ForEach(transport.devices.sorted { $0.rssi > $1.rssi }) { d in
                        Button {
                            Task { await connect(d) }
                        } label: {
                            HStack {
                                Text(d.name)
                                Spacer()
                                if connectingID == d.id {
                                    ProgressView()
                                } else {
                                    Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(connectingID != nil)
                    }
                }
                if connectingID != nil {
                    Section { Text(obd.status).foregroundStyle(.secondary) }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("OBD2 сканер")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(transport.isScanning ? "Стоп" : "Поиск") {
                        transport.isScanning ? transport.stopScan() : transport.startScan()
                    }
                }
            }
            .onAppear { transport.startScan() }
            .onChange(of: transport.bluetoothReady) { _, ready in
                if ready { transport.startScan() }
            }
        }
    }

    private func connect(_ d: DiscoveredDevice) async {
        connectingID = d.id
        errorText = nil
        do {
            try await transport.connect(d)
            try await obd.setup()
        } catch {
            errorText = error.localizedDescription
            transport.disconnect()
            transport.startScan()
        }
        connectingID = nil
    }
}

// MARK: - Живые данные

struct LiveView: View {
    @EnvironmentObject var obd: OBDService
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    tile("Обороты", obd.live.rpm, "об/мин")
                    tile("Скорость", obd.live.speed, "км/ч")
                    tile("Охлаждающая жидкость", obd.live.coolant, "°C")
                    tile("Воздух на впуске", obd.live.intakeTemp, "°C")
                    tile("Дроссель", obd.live.throttle, "%")
                    tile("Нагрузка двигателя", obd.live.load, "%")
                }
                .padding()
            }
            .navigationTitle("Живые данные")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отключить", role: .destructive) { obd.disconnect() }
                }
            }
            .onAppear { obd.startPolling() }
            .onDisappear { Task { await obd.stopPolling() } }
        }
    }

    private func tile(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Коды ошибок

struct DTCView: View {
    @EnvironmentObject var obd: OBDService
    @State private var busy = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Check Engine") {
                        Text(obd.milOn.map { $0 ? "Горит" : "Не горит" } ?? "—")
                    }
                }
                Section("Сохранённые коды") { rows(obd.stored) }
                Section("Ожидающие коды") { rows(obd.pending) }
                if let e = obd.lastError {
                    Section { Text(e).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Коды ошибок")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Сбросить", role: .destructive) { confirmClear = true }.disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy { ProgressView() } else { Button("Считать") { Task { await read() } } }
                }
            }
            .confirmationDialog("Сбросить коды ошибок?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) { Task { await clear() } }
            } message: {
                Text("Будут стёрты коды и freeze frame, обнулится готовность мониторов. Причина неисправности при этом не устраняется.")
            }
            .task { await read() }
        }
    }

    @ViewBuilder
    private func rows(_ codes: [String]) -> some View {
        if codes.isEmpty {
            Text("Нет").foregroundStyle(.secondary)
        } else {
            ForEach(codes, id: \.self) { Text($0).font(.body.monospaced()) }
        }
    }

    private func read() async {
        busy = true
        await obd.readDTCs()
        busy = false
    }

    private func clear() async {
        busy = true
        await obd.clearDTCs()
        busy = false
    }
}
