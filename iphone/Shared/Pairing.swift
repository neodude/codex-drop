import Foundation
import Security

struct Pairing: Codable, Equatable, Sendable {
    let v: Int
    let service: String
    let pin: String
    let token: String

    static func parse(_ text: String) throws -> Self {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "codexshot", url.host == "pair", url.path.isEmpty,
              url.queryItems?.count == 1, let item = url.queryItems?.first,
              item.name == "data", let raw = item.value, raw.count <= 2048,
              raw.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw ReceiverError.message("This is not a Codex pairing code.")
        }
        let encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)) else {
            throw ReceiverError.message("The pairing code is incomplete.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.v == 1,
              value.service.range(of: "^CodexShot-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil,
              value.pin.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              value.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw ReceiverError.message("The pairing code has an unsupported format.")
        }
        return value
    }
}

enum ReceiverError: LocalizedError {
    case message(String)
    case unsupportedImageFormat(String)
    var isUnsupportedImageFormat: Bool {
        if case .unsupportedImageFormat = self { true } else { false }
    }
    var errorDescription: String? {
        switch self {
        case let .message(text), let .unsupportedImageFormat(text): text
        }
    }
}

enum PairingStore {
    private static func query(account: String = "receiver") throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String,
              !group.contains("$("), !group.isEmpty else {
            throw ReceiverError.message("The app needs signing with its shared Keychain entitlement.")
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "CodexShot.Pairing.v1",
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }
    static func load() throws -> Pairing? {
        var attributes = try query(); attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReceiverError.message("Unlock your iPhone to read its Mac pairing.")
        }
        return try JSONDecoder().decode(Pairing.self, from: data)
    }
    static func save(_ pairing: Pairing) throws {
        let attributes = try query(), data = try JSONEncoder().encode(pairing)
        let status = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = attributes; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ReceiverError.message("Could not save the shared Mac pairing. Check app signing.")
            }
        } else if status != errSecSuccess { throw ReceiverError.message("Could not update the Mac pairing.") }
    }
    static func remove() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReceiverError.message("Could not remove the pairing.") }
    }
    static func saveTiming(_ timings: [String: Int]) {
        guard let attributes = try? query(account: "last-transfer-timing"), let data = try? JSONEncoder().encode(timings) else { return }
        let status = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = attributes; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
    static func loadTiming() -> [String: Int] {
        guard var attributes = try? query(account: "last-transfer-timing") else { return [:] }
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }
}
