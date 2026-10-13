import CryptoKit
import Foundation
import Models

/// SHA-256 over a canonical, length-prefixed encoding of everything that determines what runs
/// (AGENTS.md §8.2). Env *names* are included; env *values* never are.
public enum ScriptFingerprint {
    /// Bump when the encoding changes; old approvals then require re-approval.
    public static let encodingVersion: UInt8 = 1

    public struct Input: Sendable, Equatable {
        /// Canonical (realpath) project path.
        public var projectPath: String
        public var command: LaunchCommand
        /// Script body including any pre/post hooks the package manager would run.
        public var resolvedScript: String?
        /// Make/Just recipe lines, the Procfile line, or the compose file bytes.
        public var sourceMaterial: Data?
        /// Env file names (relative), e.g. `.env.local`.
        public var envFileNames: [String]
        /// Keys of `envOverrides`. Values are deliberately excluded.
        public var envOverrideKeys: [String]
        /// Version-manager prefix, e.g. `["mise", "exec", "--"]`; empty when none.
        public var wrapper: [String]

        public init(
            projectPath: String,
            command: LaunchCommand,
            resolvedScript: String?,
            sourceMaterial: Data? = nil,
            envFileNames: [String] = [],
            envOverrideKeys: [String] = [],
            wrapper: [String] = []
        ) {
            self.projectPath = projectPath
            self.command = command
            self.resolvedScript = resolvedScript
            self.sourceMaterial = sourceMaterial
            self.envFileNames = envFileNames
            self.envOverrideKeys = envOverrideKeys
            self.wrapper = wrapper
        }

        /// Builds an input from a saved project plus freshly re-resolved file contents.
        ///
        /// The command is `project.launchCommand` (including any localhost-bind arguments), and the
        /// bind's env names join the override keys, so turning the bind on or off needs approval.
        public init(project: Project, resolvedScript: String?, sourceMaterial: Data? = nil, wrapper: [String] = []) {
            self.init(
                projectPath: project.path,
                command: project.launchCommand,
                resolvedScript: resolvedScript,
                sourceMaterial: sourceMaterial,
                envFileNames: project.envFiles,
                envOverrideKeys: Set(project.envOverrides.keys).union(project.bindEnvironment.keys).sorted(),
                wrapper: wrapper
            )
        }
    }

    /// Lowercase hex SHA-256.
    public static func compute(_ input: Input) -> String {
        let digest = SHA256.hash(data: canonicalEncoding(input))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Each field is tagged and length-prefixed so no two different inputs share an encoding.
    /// Name lists are sorted: their order doesn't affect what runs.
    static func canonicalEncoding(_ input: Input) -> Data {
        var encoder = CanonicalEncoder()
        encoder.byte(encodingVersion)
        encoder.field("path", input.projectPath)
        switch input.command {
        case .argv(let args):
            encoder.field("cmd", "argv")
            encoder.list("argv", args)
        case .shell(let string):
            encoder.field("cmd", "shell")
            encoder.field("shell", string)
        }
        encoder.optional("script", input.resolvedScript.map { Data($0.utf8) })
        encoder.optional("source", input.sourceMaterial)
        encoder.list("envFiles", input.envFileNames.sorted())
        encoder.list("envKeys", input.envOverrideKeys.sorted())
        encoder.list("wrapper", input.wrapper)
        return encoder.data
    }

    private struct CanonicalEncoder {
        var data = Data()

        mutating func byte(_ value: UInt8) {
            data.append(value)
        }

        mutating func length(_ value: Int) {
            withUnsafeBytes(of: UInt64(value).bigEndian) { data.append(contentsOf: $0) }
        }

        mutating func raw(_ bytes: Data) {
            length(bytes.count)
            data.append(bytes)
        }

        mutating func field(_ tag: String, _ value: String) {
            raw(Data(tag.utf8))
            raw(Data(value.utf8))
        }

        mutating func optional(_ tag: String, _ value: Data?) {
            raw(Data(tag.utf8))
            if let value {
                byte(1)
                raw(value)
            } else {
                byte(0)
            }
        }

        mutating func list(_ tag: String, _ values: [String]) {
            raw(Data(tag.utf8))
            length(values.count)
            for value in values { raw(Data(value.utf8)) }
        }
    }
}
