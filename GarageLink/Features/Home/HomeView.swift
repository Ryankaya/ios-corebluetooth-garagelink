import GarageProtocol
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var registry: DeviceRegistry
    @EnvironmentObject private var ble: BLECentral
    @State private var addDeviceLink: AddDeviceRequest?
    @State private var showVirtualPanel = false

    struct AddDeviceRequest: Identifiable {
        let id = UUID()
        let link: PairingLink?
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem = ble.availability.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if registry.devices.isEmpty {
                    Section {
                        EmptyDevicesView { addDeviceLink = AddDeviceRequest(link: nil) }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section("My devices") {
                        ForEach(registry.devices) { device in
                            NavigationLink(value: device) {
                                DeviceRow(device: device)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        TrafficLogView()
                    } label: {
                        Label("Protocol inspector", systemImage: "waveform.path.ecg.rectangle")
                    }
                    Button {
                        showVirtualPanel = true
                    } label: {
                        Label("Virtual device panel", systemImage: "cpu")
                    }
                } footer: {
                    Text("The virtual device runs the same firmware logic as the Mac simulator, so everything works in the iOS Simulator too.")
                }
            }
            .navigationTitle("GarageLink")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addDeviceLink = AddDeviceRequest(link: nil)
                    } label: {
                        Label("Add device", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: PairedDevice.self) { device in
                DeviceControlView(device: device, env: env)
            }
            .sheet(item: $addDeviceLink) { request in
                AddDeviceView(env: env, link: request.link)
            }
            .sheet(isPresented: $showVirtualPanel) {
                VirtualDevicePanelView(device: env.virtualGarage)
            }
            .onReceive(env.$pendingLink.compactMap { $0 }) { link in
                env.pendingLink = nil
                addDeviceLink = AddDeviceRequest(link: link)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: PairedDevice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "door.garage.closed")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.headline)
                Text("\(device.transport.title) · \(GarageGATT.advertisedName(for: device.deviceID)) · fw \(device.firmware)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyDevicesView: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("No devices yet").font(.title3.bold())
            Text("Put your GarageLink controller in pairing mode, then add it here. You can also scan its QR code with the Camera or tap its NFC tag.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: add) {
                Label("Add device", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}
