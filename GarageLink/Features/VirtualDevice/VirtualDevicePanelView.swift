import CoreImage.CIFilterBuiltins
import GarageProtocol
import SwiftUI

/// The physical side of the virtual controller: the buttons, sensor and label a real unit would have.
struct VirtualDevicePanelView: View {
    @ObservedObject var device: VirtualGarage
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    lcd
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Hardware") {
                    Button {
                        device.pressPairButton()
                    } label: {
                        Label(device.status.pairingMode ? "PAIR (pairing mode, \(device.pairingSecondsLeft)s left)" : "Press PAIR button", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button {
                        device.pressWallButton()
                    } label: {
                        Label("Press wall button", systemImage: "button.programmable")
                    }
                    Toggle(isOn: Binding(get: { device.status.obstructed }, set: { device.setObstruction($0) })) {
                        Label("Safety beam blocked", systemImage: "exclamationmark.triangle")
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = qrImage(device.core.pairingURL) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 96, height: 96)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Setup code").font(.caption).foregroundStyle(.secondary)
                            Text("\(device.core.setupCode.prefix(3)) \(device.core.setupCode.suffix(3))")
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                            Text(device.advertisedName).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Device label")
                } footer: {
                    Text("On real hardware this label, QR code and NFC sticker are printed on the unit.")
                }

                Section("Device log") {
                    if device.activity.isEmpty {
                        Text("No events yet").foregroundStyle(.secondary)
                    }
                    ForEach(Array(device.activity.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }

                Section {
                    Button("Factory reset", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("New device ID and setup code; paired phones are forgotten by the device.")
                }
            }
            .navigationTitle("Virtual device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Factory reset the virtual device?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { device.factoryReset() }
            }
        }
    }

    private var lcd: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(device.status.door.label.uppercased())
                Spacer()
                Text("\(device.status.position)%")
            }
            .font(.system(size: 26, weight: .bold, design: .monospaced))
            ProgressView(value: Double(device.status.position), total: 100)
                .tint(.green)
            HStack {
                Text(device.status.pairingMode ? "PAIRING \(device.pairingSecondsLeft)s" : "PAIRING OFF")
                Spacer()
                Text("\(device.status.pairedClients) PHONES")
                Spacer()
                Text("\(device.connectionCount) LINKED")
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.green)
        .padding(14)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
    }

    private func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
