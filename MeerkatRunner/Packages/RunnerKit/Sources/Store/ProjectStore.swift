import CryptoKit
import Foundation
import Models

public enum StoreError: Error, Sendable {
    case key(StoreKeyError)
    case io(String)
    case corrupt
    case unsupportedVersion(Int)
}

/// Persists projects as `{ version, projects, mac }` (AGENTS.md §3, §8.3).
///
/// The MAC is HMAC-SHA256 over the canonical encoding of `projects`, keyed from the Keychain.
/// This is tamper-*evidence*, not tamper-proofing: anything running as the user can also read the
/// Keychain item. Its job is to make an edited store fail closed (every approval invalidated) rather
/// than silently run a command the user never saw.
public actor ProjectStore {
    public static let currentVersion = 1

    struct Envelope: Codable {
        var version: Int
        var projects: [Project]
        /// Hex HMAC-SHA256.
        var mac: String?
    }

    public struct LoadResult: Sendable {
        public var projects: [Project]
        /// `false` when the MAC was missing or wrong. Approvals have already been cleared;
        /// show the one-time warning.
        public var integrityOK: Bool
    }

    private let paths: StorePaths
    private let keyProvider: any StoreKeyProvider

    public init(paths: StorePaths = .standard, keyProvider: any StoreKeyProvider = KeychainStoreKey()) {
        self.paths = paths
        self.keyProvider = keyProvider
    }

    public func load() throws(StoreError) -> LoadResult {
        let url = paths.projectsFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadResult(projects: [], integrityOK: true)
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        } catch {
            throw .corrupt
        }
        guard envelope.version <= Self.currentVersion else { throw .unsupportedVersion(envelope.version) }
        // TODO: schema migrations go here when currentVersion > 1.

        let expected = try mac(for: envelope.projects)
        if let stored = envelope.mac, Self.constantTimeEquals(stored, expected) {
            return LoadResult(projects: envelope.projects, integrityOK: true)
        }
        var projects = envelope.projects
        for index in projects.indices { projects[index].approval = nil }
        return LoadResult(projects: projects, integrityOK: false)
    }

    /// Atomic write, then `chmod 0600`. The directory is created with mode 0700.
    public func save(_ projects: [Project]) throws(StoreError) {
        let envelope = Envelope(version: Self.currentVersion, projects: projects, mac: try mac(for: projects))
        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: paths.supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Self.encoder().encode(envelope)
            try data.write(to: paths.projectsFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.projectsFile.path)
        } catch {
            throw .io(String(describing: type(of: error)))
        }
    }

    // MARK: - Integrity

    /// Canonical encoding: sorted keys, default (lossless) date encoding, so decode → re-encode is stable.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func canonicalEncoding(_ projects: [Project]) throws(StoreError) -> Data {
        do {
            return try encoder().encode(projects)
        } catch {
            throw .corrupt
        }
    }

    private func mac(for projects: [Project]) throws(StoreError) -> String {
        let keyData: Data
        do {
            keyData = try keyProvider.key()
        } catch {
            throw .key(error)
        }
        let code = HMAC<SHA256>.authenticationCode(
            for: try Self.canonicalEncoding(projects),
            using: SymmetricKey(data: keyData)
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices { diff |= left[index] ^ right[index] }
        return diff == 0
    }
}
