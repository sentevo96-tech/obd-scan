import SwiftUI

@main
struct OBDScannerApp: App {
    @StateObject private var transport: BLETransport
    @StateObject private var obd: OBDService

    init() {
        let t = BLETransport()
        _transport = StateObject(wrappedValue: t)
        _obd = StateObject(wrappedValue: OBDService(transport: t))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(transport)
                .environmentObject(obd)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var obd: OBDService

    var body: some View {
        if obd.isReady {
            TabView {
                LiveView()
                    .tabItem { Label("Данные", systemImage: "gauge.with.dots.needle.67percent") }
                DTCView()
                    .tabItem { Label("Ошибки", systemImage: "exclamationmark.triangle") }
            }
        } else {
            ScanView()
        }
    }
}
