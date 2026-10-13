import Foundation
import Models

/// Classifies a listening socket's local address (AGENTS.md §4 step 4).
public enum AddressClassifier {
    /// - Parameter bytes: 4 bytes for IPv4, 16 for IPv6, in network order.
    public static func classify(bytes: [UInt8], isIPv6: Bool) -> ListenAddress {
        if isIPv6 {
            guard bytes.count == 16 else { return .specific("?") }
            if bytes.allSatisfy({ $0 == 0 }) { return .wildcard }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
            // IPv4-mapped (::ffff:a.b.c.d) → classify the embedded v4 address.
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return classify(bytes: Array(bytes[12..<16]), isIPv6: false)
            }
            return .specific(format(bytes: bytes, isIPv6: true))
        } else {
            guard bytes.count == 4 else { return .specific("?") }
            if bytes.allSatisfy({ $0 == 0 }) { return .wildcard }
            if bytes[0] == 127 { return .loopback }
            return .specific(format(bytes: bytes, isIPv6: false))
        }
    }

    static func format(bytes: [UInt8], isIPv6: Bool) -> String {
        if !isIPv6 {
            return bytes.map(String.init).joined(separator: ".")
        }
        var groups: [String] = []
        for index in stride(from: 0, to: 16, by: 2) {
            let value = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            groups.append(String(value, radix: 16))
        }
        return groups.joined(separator: ":")
    }
}
