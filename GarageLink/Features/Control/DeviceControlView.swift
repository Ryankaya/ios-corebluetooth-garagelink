import GarageProtocol
import SwiftUI

struct DeviceControlView: View {
    @StateObject private var model: DeviceControlViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var isVisible = false

    init(device: PairedDevice, env: AppEnvironment) {
        _model = StateObject(wrappedValue: DeviceControlViewModel(device: device, env: env))
    }

    private var isConnected: Bool { model.link == .connected }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                connectionBanner

                DoorGraphic(position: Double(model.status?.position ?? 0) / 100, obstructed: model.status?.obstructed ?? false)
                    .frame(height: 230)
                    .opacity(isConnected ? 1 : 0.45)
                    .accessibilityLabel("Garage door \(model.headline)")

                VStack(spacing: 4) {
                    Text(model.headline)
                        .font(.title.bold())
                        .contentTransition(.numericText())
                    if model.status?.obstructed == true {
                        Label("Safety sensor blocked", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                primaryButton

                HStack(spacing: 12) {
                    secondaryButton(.open, systemImage: "arrow.up")
                    secondaryButton(.stop, systemImage: "stop.fill")
                    secondaryButton(.close, systemImage: "arrow.down")
                }

                detailsCard
            }
            .padding()
        }
        .navigationTitle(model.device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink {
                        TrafficLogView()
                    } label: {
                        Label("Protocol inspector", systemImage: "waveform.path.ecg.rectangle")
                    }
                    Button(role: .destructive) {
                        confirmForget = true
                    } label: {
                        Label("Forget device", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Forget \(model.device.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget device", role: .destructive) {
                Task {
                    await model.forget()
                    dismiss()
                }
            }
        } message: {
            Text("The device is asked to delete this iPhone's key, and the key is removed from the Keychain. You'll need the setup code to pair again.")
        }
        .alert("GarageLink", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear {
            isVisible = true
            model.activate()
        }
        .onDisappear {
            isVisible = false
            model.deactivate()
        }
        .onChange(of: scenePhase) { phase in
            // Don't hold a BLE link open in the background: it drains the device's battery too.
            if phase == .active, isVisible { model.activate() } else if phase == .background { model.deactivate() }
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        HStack(spacing: 10) {
            switch model.link {
            case .connected:
                Circle().fill(.green).frame(width: 9, height: 9)
                Text("Connected").font(.subheadline.weight(.semibold))
                Spacer()
                if let rssi = model.rssi { SignalBars(rssi: rssi) }
            case .connecting, .disconnected:
                ProgressView().controlSize(.small)
                Text("Connecting to \(GarageGATT.advertisedName(for: model.device.deviceID))…").font(.subheadline)
                Spacer()
            case let .retrying(seconds, reason):
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Retrying in \(seconds)s").font(.subheadline.weight(.semibold))
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Retry") { model.retryNow() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var primaryButton: some View {
        let action = model.primaryAction
        return Button {
            Task { await model.send(action) }
        } label: {
            HStack {
                if model.sending == action {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: icon(for: action))
                }
                Text(title(for: action)).bold()
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(action == .stop ? .red : .orange)
        .disabled(!isConnected || model.sending != nil)
    }

    private func secondaryButton(_ opcode: Opcode, systemImage: String) -> some View {
        Button {
            Task { await model.send(opcode) }
        } label: {
            Label(title(for: opcode), systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!isConnected || model.sending != nil)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow("Transport", model.device.transport.title)
            detailRow("Advertised as", GarageGATT.advertisedName(for: model.device.deviceID))
            detailRow("Firmware", model.device.firmware)
            detailRow("Phones paired to device", model.status.map { "\($0.pairedClients)" } ?? "—")
            detailRow("Paired", model.device.pairedAt.formatted(date: .abbreviated, time: .shortened))
            Text("Each command reads a one-time challenge from the device and is signed with HMAC-SHA256, so a recorded command can't be replayed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func title(for opcode: Opcode) -> String {
        switch opcode {
        case .open: return "Open"
        case .close: return "Close"
        case .stop: return "Stop"
        case .toggle: return "Toggle"
        case .unpair: return "Unpair"
        }
    }

    private func icon(for opcode: Opcode) -> String {
        switch opcode {
        case .open: return "door.garage.open"
        case .close: return "door.garage.closed"
        case .stop: return "stop.fill"
        case .toggle, .unpair: return "arrow.up.arrow.down"
        }
    }
}

/// Garage opening with a sectional door that rolls up with `position` (0 closed … 1 open).
struct DoorGraphic: View {
    let position: Double
    let obstructed: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let roofHeight = height * 0.2
            let openingInset = width * 0.14
            let openingWidth = width - openingInset * 2
            let openingHeight = height - roofHeight - 8
            let panelCount = 5
            let panelHeight = openingHeight / CGFloat(panelCount)

            ZStack(alignment: .top) {
                // House front + roof
                Path { path in
                    path.move(to: CGPoint(x: 0, y: roofHeight))
                    path.addLine(to: CGPoint(x: width / 2, y: 0))
                    path.addLine(to: CGPoint(x: width, y: roofHeight))
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height))
                    path.closeSubpath()
                }
                .fill(Color(.tertiarySystemFill))

                // Interior with the car
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color.black.opacity(0.85), Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "car.side.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: openingWidth * 0.55)
                        .foregroundStyle(.gray)
                        .padding(.bottom, 8)
                    if obstructed {
                        Rectangle()
                            .fill(Color.red)
                            .frame(height: 2)
                            .padding(.bottom, 14)
                            .shadow(color: .red, radius: 4)
                    }
                }
                .frame(width: openingWidth, height: openingHeight)
                .offset(y: roofHeight)

                // Door panels roll up out of the opening
                VStack(spacing: 2) {
                    ForEach(0..<panelCount, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.24), Color(red: 0.93, green: 0.49, blue: 0.13)], startPoint: .top, endPoint: .bottom))
                            .frame(height: panelHeight - 2)
                            .overlay(
                                HStack(spacing: openingWidth * 0.06) {
                                    ForEach(0..<4, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: 1).stroke(Color.black.opacity(0.12), lineWidth: 1)
                                    }
                                }
                                .padding(6)
                            )
                    }
                }
                // Solid backing so the seams between panels don't show the interior through the door.
                .background(Color(red: 0.55, green: 0.3, blue: 0.08))
                .offset(y: -openingHeight * position)
                .frame(width: openingWidth, height: openingHeight, alignment: .top)
                .clipped()
                .offset(y: roofHeight)
                .animation(.linear(duration: 0.12), value: position)
            }
        }
    }
}
