import Foundation
import Security

struct ReadingContext: Codable, Equatable {
    var book: String = ""
    var chapter: String = ""
    var page: Int = 0
    var progress: Double = 0
    var text: String = ""
    var updatedAt: TimeInterval = 0

    static let empty = ReadingContext()

    var pageLabel: String {
        guard page > 0 else { return "未连接" }
        return "第 \(page) 页"
    }
}

struct ChatTurn: Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id = UUID()
    var role: Role
    var text: String
}

enum KeychainStore {
    private static let service = "com.cg.readingcompanion"

    static func read(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func save(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum LocalNetwork {
    static func ipv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == AF_INET else { continue }
            let name = String(cString: interface.ifa_name)
            guard name != "lo0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let address = String(cString: hostname)
                if !results.contains(address) {
                    results.append(address)
                }
            }
        }
        return results
    }

    static func bestAddress() -> String {
        let addresses = ipv4Addresses()
        if let hotspot = addresses.first(where: { $0.hasPrefix("172.20.10.") }) {
            return hotspot
        }
        if let wifi = addresses.first(where: { $0.hasPrefix("192.168.") }) {
            return wifi
        }
        return addresses.first ?? "127.0.0.1"
    }
}
