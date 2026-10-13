import Foundation
import Security

public enum StoreKeyError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case randomFailed(OSStatus)
}

/// Supplies the 32-byte HMAC key for the project store.
public protocol StoreKeyProvider: Sendable {
    func key() throws(StoreKeyError) -> Data
}

/// Random 32-byte key in the login Keychain, created on first launch (AGENTS.md §3).
public struct KeychainStoreKey: StoreKeyProvider {
    public static let service = "us.okayplus.meerkat-runner.store"
    public static let account = "projects-hmac"

    public init() {}

    public func key() throws(StoreKeyError) -> Data {
        if let existing = try read() { return existing }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw .randomFailed(status) }
        try add(bytes)
        return bytes
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    private func read() throws(StoreKeyError) -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw .keychain(status)
        }
    }

    private func add(_ key: Data) throws(StoreKeyError) {
        var query = baseQuery()
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }
    }
}

/// Fixed key for tests.
public struct StaticStoreKey: StoreKeyProvider {
    public var value: Data

    public init(_ value: Data) {
        self.value = value
    }

    public func key() throws(StoreKeyError) -> Data { value }
}
