import GarageProtocol
import SwiftUI

@MainActor
final class PairingViewModel: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case ready(DeviceInfo)
        case pairing(DeviceInfo)
        case paired(PairedDevice)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published var setupCode: String
    @Published var errorMessage: String?

    let peripheral: DiscoveredPeripheral
    let transport: TransportKind
    private let env: AppEnvironment
    private let expectedDeviceID: ShortID?
    private var client: GarageClient?
    private let nfc = NFCPairingReader()

    init(env: AppEnvironment, peripheral: DiscoveredPeripheral, transport: TransportKind, link: PairingLink?) {
        self.env = env
        self.peripheral = peripheral
        self.transport = transport
        self.expectedDeviceID = link?.deviceID
        self.setupCode = link?.setupCode ?? ""
    }

    var canUseNFC: Bool { NFCPairingReader.isAvailable }
    var codeIsValid: Bool { GarageCrypto.isValidSetupCode(setupCode) }

    func connect() async {
        guard client == nil else { return }
        phase = .connecting
        do {
            let connection = try await env.scanner(for: transport).connect(to: peripheral.id, timeout: 10)
            let client = GarageClient(connection: connection, log: env.log)
            client.onDisconnect = { [weak self] _ in
                guard let self else { return }
                self.client = nil
                if case .paired = self.phase { return }
                self.phase = .failed("The device disconnected.")
            }
            self.client = client
            let info = try await client.prepare(expecting: expectedDeviceID)
            if env.registry.devices.contains(where: { $0.deviceID == info.deviceID }) {
                errorMessage = "This phone is already paired with \(info.name). Pairing again replaces the old key."
            }
            phase = .ready(info)
        } catch {
            client?.disconnect()
            client = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func pair() async {
        guard case let .ready(info) = phase, let client else { return }
        guard codeIsValid else {
            errorMessage = "Enter the 6-digit code printed on the device."
            return
        }
        errorMessage = nil
        phase = .pairing(info)
        do {
            let key = try await client.pair(setupCode: setupCode, clientID: env.registry.clientID)
            let device = PairedDevice(
                deviceID: info.deviceID,
                name: info.name,
                transport: transport,
                peripheralID: peripheral.id,
                firmware: info.firmwareString,
                pairedAt: Date()
            )
            try env.registry.add(device, key: key)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .paired(device)
            client.disconnect()
            self.client = nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = error.localizedDescription
            if case LinkError.att(.badSetupCode) = error { setupCode = "" }
            phase = self.client == nil ? .failed(error.localizedDescription) : .ready(info)
        }
    }

    func scanTag() async {
        do {
            await apply(try await nfc.read())
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Uses a pairing link from an NFC tag or QR code, if it belongs to the connected device.
    func apply(_ link: PairingLink) async {
        if let expectedDeviceID, link.deviceID != expectedDeviceID {
            errorMessage = "That code belongs to a different device (\(link.advertisedName))."
            return
        }
        if case let .ready(info) = phase, link.deviceID != info.deviceID {
            errorMessage = "That code belongs to \(link.advertisedName), not \(GarageGATT.advertisedName(for: info.deviceID))."
            return
        }
        setupCode = link.setupCode
        await pair()
    }

    func retry() async {
        client?.disconnect()
        client = nil
        await connect()
    }

    func leave() {
        client?.disconnect()
        client = nil
    }
}

struct PairingView: View {
    @StateObject private var model: PairingViewModel
    @FocusState private var codeFocused: Bool
    @State private var showQRScanner = false
    let onPaired: () -> Void

    init(model: @autoclosure @escaping () -> PairingViewModel, onPaired: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onPaired = onPaired
    }

    var body: some View {
        Form {
            switch model.phase {
            case .connecting:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting to \(model.peripheral.name)…")
                    }
                } footer: {
                    Text("Discovering GATT services and subscribing to notifications.")
                }

            case let .ready(info), let .pairing(info):
                deviceSection(info)
                codeSection
                pairButtons

            case let .paired(device):
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.green)
                        Text("Paired with \(device.name)").font(.title3.bold())
                        Text("A 256-bit key was derived with ECDH and saved to this iPhone's Keychain. The device will only accept commands signed with it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Done", action: onPaired)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }

            case let .failed(message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try again") { Task { await model.retry() } }
                }
            }
        }
        .navigationTitle(model.peripheral.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { codeFocused = false }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            PairingQRScannerSheet { link in
                Task { await model.apply(link) }
            }
        }
        .task { await model.connect() }
        .onDisappear {
            if case .paired = model.phase { return }
            model.leave()
        }
    }

    private func deviceSection(_ info: DeviceInfo) -> some View {
        Section("Device") {
            LabeledContent("Name", value: info.name)
            LabeledContent("Firmware", value: info.firmwareString)
            LabeledContent("Protocol", value: "v\(info.protocolVersion)")
            LabeledContent("Device ID") {
                Text(info.deviceID.hex).font(.caption.monospaced())
            }
        }
    }

    private var codeSection: some View {
        Section {
            TextField("000000", text: $model.setupCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($codeFocused)
                .onChange(of: model.setupCode) { value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { model.setupCode = digits }
                    // The number pad has no return key; get it out of the way of the Pair button.
                    if digits.count == 6 { codeFocused = false }
                }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Setup code")
        } footer: {
            Text("Press PAIR on the device first. The code is on the device label; it's never sent over the air, only used to derive the key.")
        }
    }

    @ViewBuilder
    private var pairButtons: some View {
        let isPairing: Bool = {
            if case .pairing = model.phase { return true }
            return false
        }()
        Section {
            Button {
                codeFocused = false
                Task { await model.pair() }
            } label: {
                HStack {
                    Spacer()
                    if isPairing {
                        ProgressView()
                        Text("Pairing…").padding(.leading, 6)
                    } else {
                        Text("Pair").bold()
                    }
                    Spacer()
                }
            }
            .disabled(isPairing || !model.codeIsValid)

            if PairingQRScannerSheet.isSupported {
                Button {
                    codeFocused = false
                    showQRScanner = true
                } label: {
                    Label("Scan QR code on device", systemImage: "qrcode.viewfinder")
                }
                .disabled(isPairing)
            }

            if model.canUseNFC {
                Button {
                    Task { await model.scanTag() }
                } label: {
                    Label("Tap device NFC tag instead", systemImage: "wave.3.right")
                }
                .disabled(isPairing)
            }
        }
    }
}
