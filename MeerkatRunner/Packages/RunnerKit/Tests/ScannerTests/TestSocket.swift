import Darwin
import Foundation

/// A loopback TCP listener owned by the test process. Loopback only, so no firewall prompt.
final class TestSocket {
    let fd: Int32
    let port: Int
    private var isOpen = true

    private init(fd: Int32, port: Int) {
        self.fd = fd
        self.port = port
    }

    deinit { close() }

    func close() {
        guard isOpen else { return }
        isOpen = false
        Darwin.close(fd)
    }

    /// Listens on 127.0.0.1 or ::1. `port` 0 picks a free port.
    static func listen(v6: Bool, port: Int = 0) throws -> TestSocket {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }

        var bound: Int32
        if v6 {
            var only: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var loopback = in6_addr()
            withUnsafeMutableBytes(of: &loopback) { $0[15] = 1 }
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = loopback
            bound = withUnsafePointer(to: addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            bound = withUnsafePointer(to: addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let error = posixError()
            Darwin.close(fd)
            throw error
        }

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            let error = posixError()
            Darwin.close(fd)
            throw error
        }
        // sin_port and sin6_port share the same offset.
        let networkPort = withUnsafePointer(to: storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
        }
        return TestSocket(fd: fd, port: Int(UInt16(bigEndian: networkPort)))
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
