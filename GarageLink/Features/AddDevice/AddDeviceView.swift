import GarageProtocol
import SwiftUI

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var transport: TransportKind {
        didSet { if oldValue != transport { start() } }
    }
    @Published private(set) var results: [DiscoveredPeripheral] = []

    private let env: AppEnvironment
    private var scanTask: Task<Void, Never>?

    init(env: AppEnvironment, transport: TransportKind) {
        self.env = env
        self.transport = transport
    }

    func start() {
        scanTask?.cancel()
        results = []
        let stream = env.scanner(for: transport).scan()
        scanTask = Task { [weak self] in
            for await discovery in stream {
                self?.upsert(discovery)
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func upsert(_ discovery: DiscoveredPeripheral) {
        if let index = results.firstIndex(where: { $0.id == discovery.id }) {
            results[index] = discovery
        } else {
            results.append(discovery)
        }
        // Drop devices we haven't heard from recently (powered off / out of range).
        let cutoff = Date().addingTimeInterval(-6)
        results.removeAll { $0.lastSeen < cutoff }
        results.sort { $0.rssi > $1.rssi }
    }
}

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scan: ScanViewModel
    @State private var path: [DiscoveredPeripheral] = []
    @State private var link: PairingLink?
    @State private var showQRScanner = false
    private let env: AppEnvironment

    init(env: AppEnvironment, link: PairingLink?) {
        self.env = env
        _link = State(initialValue: link)
        let transport = link.map { Self.transport(for: $0, env: env) } ?? .preferred
        _scan = StateObject(wrappedValue: ScanViewModel(env: env, transport: transport))
    }

    private static func transport(for link: PairingLink, env: AppEnvironment) -> TransportKind {
        link.deviceID == env.virtualGarage.info.deviceID ? .virtual : .bluetooth
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Connection", selection: $scan.transport) {
                        ForEach(TransportKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if PairingQRScannerSheet.isSupported {
                    Section {
                        Button {
                            showQRScanner = true
                        } label: {
                            Label("Scan QR code on device", systemImage: "qrcode.viewfinder")
                        }
                    }
                }

                if let link {
                    Section {
                        Label("Looking for \(link.advertisedName) from the pairing code you scanned…", systemImage: "qrcode.viewfinder")
                            .font(.subheadline)
                    }
                }

                Section {
                    if scan.results.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(scan.transport == .bluetooth ? "Scanning for GarageLink devices…" : "Starting virtual device…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(scan.results) { peripheral in
                        NavigationLink(value: peripheral) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peripheral.name).font(.body.monospaced().weight(.semibold))
                                    Text(scan.transport == .virtual ? "Simulated in this app" : "Bluetooth LE")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                SignalBars(rssi: peripheral.rssi)
                            }
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    if scan.transport == .bluetooth {
                        Text("Run GarageSim on your Mac (or power on the hardware controller) to see it here. The iOS Simulator has no Bluetooth; use Virtual device there.")
                    }
                }
            }
            .navigationTitle("Add device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: DiscoveredPeripheral.self) { peripheral in
                PairingView(
                    model: PairingViewModel(env: env, peripheral: peripheral, transport: scan.transport, link: matchingLink(for: peripheral)),
                    onPaired: { dismiss() }
                )
            }
            .onAppear { scan.start() }
            .onDisappear { scan.stop() }
            .sheet(isPresented: $showQRScanner) {
                PairingQRScannerSheet { scanned in
                    link = scanned
                    let transport = Self.transport(for: scanned, env: env)
                    if scan.transport != transport { scan.transport = transport }
                    openMatch(in: scan.results)
                }
            }
            .onChange(of: scan.results) { results in
                openMatch(in: results)
            }
        }
    }

    /// Came from a QR code / NFC tag: jump straight to pairing once that device shows up nearby.
    private func openMatch(in results: [DiscoveredPeripheral]) {
        guard path.isEmpty, let link, let match = results.bestCandidate(for: link.deviceID) else { return }
        path = [match]
    }

    /// The link travels with any device that could be it; pairing then checks the device ID the
    /// device itself reports, so a wrong guess fails with "a different device answered".
    private func matchingLink(for peripheral: DiscoveredPeripheral) -> PairingLink? {
        guard let link, peripheral.deviceIDPrefix == nil || peripheral.deviceIDPrefix == String(link.deviceID.hex.prefix(6)) else { return nil }
        return link
    }
}

extension Array where Element == DiscoveredPeripheral {
    /// Prefers an exact advertised-name match ("GL-A1B2C3"). The name isn't always visible: an iPhone
    /// that already knows a Mac through the same Apple ID reports the Mac's own name instead. So any
    /// device advertising the GarageLink service without a GL- name is a fallback candidate.
    func bestCandidate(for deviceID: ShortID) -> DiscoveredPeripheral? {
        let prefix = String(deviceID.hex.prefix(6))
        if let exact = first(where: { $0.deviceIDPrefix == prefix }) { return exact }
        return filter { $0.deviceIDPrefix == nil }.max { $0.rssi < $1.rssi }
    }
}

extension DiscoveredPeripheral: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        switch rssi {
        case (-60)...: return 4
        case (-70)...: return 3
        case (-80)...: return 2
        default: return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level ? Color.orange : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(4 + bar * 3))
            }
            Text("\(rssi) dBm")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(level) of 4, \(rssi) dBm")
    }
}
