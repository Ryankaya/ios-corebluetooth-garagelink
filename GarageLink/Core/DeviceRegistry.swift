import CryptoKit
import Foundation
import GarageProtocol
import Security

struct PairedDevice: Codable, Identifiable, Hashable {
    let deviceID: ShortID
    var name: String
    let transport: TransportKind
    /// CoreBluetooth identifier from the last connection. Not stable forever: devices that rotate
    /// their address get a new one, so reconnects fall back to scanning for the advertised name.
    var peripheralID: UUID
    var firmware: String
    let pairedAt: Date

    var id: ShortID { deviceID }
}

/// Paired devices. Metadata lives in UserDefaults; pairing keys and this phone's client ID live
/// in the Keychain (after-first-unlock, this-device-only, so background BLE reconnects can use them
/// but they never sync to iCloud or restore onto another phone).
@MainActor
final class DeviceRegistry: ObservableObject {
    @Published private(set) var devices: [PairedDevice] = []
    let clientID: ShortID

    private let defaultsKey = "pairedDevices"

    init() {
        if let data = Keychain.read(account: "client-id"), let id = ShortID(bytes: data) {
            clientID = id
        } else {
            clientID = .random()
            try? Keychain.write(clientID.bytes, account: "client-id")
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            // Drop metadata whose key is gone (e.g. Keychain reset).
            devices = decoded.filter { key(for: $0) != nil }
        }
    }

    func key(for device: PairedDevice) -> SymmetricKey? {
        Keychain.read(account: keyAccount(device.deviceID)).map { SymmetricKey(data: $0) }
    }

    func add(_ device: PairedDevice, key: SymmetricKey) throws {
        try Keychain.write(key.rawData, account: keyAccount(device.deviceID))
        devices.removeAll { $0.deviceID == device.deviceID }
        devices.append(device)
        save()
    }

    func remove(_ device: PairedDevice) {
        Keychain.delete(account: keyAccount(device.deviceID))
        devices.removeAll { $0.deviceID == device.deviceID }
        save()
    }

    func updatePeripheralID(_ peripheralID: UUID, for deviceID: ShortID) {
        guard let index = devices.firstIndex(where: { $0.deviceID == deviceID }), devices[index].peripheralID != peripheralID else { return }
        devices[index].peripheralID = peripheralID
        save()
    }

    private func keyAccount(_ id: ShortID) -> String { "device-key.\(id.hex)" }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

enum Keychain {
    private static let service = "com.ryankaya.garagelink"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error \(status)" }
    }

    static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
