import Darwin
import Foundation

/// Untrusted discovery input, never a replacement for peer/header/filter checks.
/// Shared by release generation, refresh, and the census publisher.
public struct CensusCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var host: String
        public var port: UInt16
        public var userAgent: String
        public var startHeight: Int32
        public init(host: String, port: UInt16, userAgent: String, startHeight: Int32) {
            self.host = host; self.port = port; self.userAgent = userAgent; self.startHeight = startHeight
        }
        public var endpoint: PeerEndpoint { PeerEndpoint(host: host, port: port) }
    }
    public var schemaVersion: Int
    public var date: String
    public var tip: Int32
    public var networks: [String: [Entry]]
    public init(schemaVersion: Int = 1, date: String, tip: Int32, networks: [String: [Entry]]) {
        self.schemaVersion = schemaVersion; self.date = date; self.tip = tip; self.networks = networks
    }
    public static let endpoint = URL(string: "https://census.winnowwallet.com/census/peers.json")!
    public static let maximumBytes = 4 * 1_024 * 1_024
    public static let overlayCap = 2_000
    public static let maximumAgeDays = 7
    /// Below this many clearnet or Tor entries a list is thin. The publisher
    /// never makes one this small — a daily census lists hundreds of clearnet
    /// and thousands of Tor nodes — so a list that arrives this small was cut
    /// down somewhere in between, and taking it would empty the automatic
    /// pool. I2P has no floor: it is delegated-only and may be empty.
    public static let minimumOverlayEntries = 50

    public enum Invalid: String, Error, LocalizedError {
        case schema, date, expired, future, size, endpoint, height, duplicate, diversity, thin
        public var errorDescription: String? { "Invalid census peer list: \(rawValue)." }
    }

    public static func day(_ text: String) -> Int? {
        guard text.utf8.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return Int(floor(date.timeIntervalSince1970 / 86_400))
    }

    public static func decode(_ data: Data, now: Date = Date(), requireFresh: Bool = true,
                              minimumEntries: Int = 0) throws -> Self {
        guard data.count <= maximumBytes else { throw Invalid.size }
        return try JSONDecoder().decode(Self.self, from: data)
            .validated(now: now, requireFresh: requireFresh, minimumEntries: minimumEntries)
    }

    /// `minimumEntries` is the floor the wallet applies to a list it will
    /// use (`minimumOverlayEntries`); the publisher and the tests validate
    /// shape alone.
    public func validated(now: Date = Date(), requireFresh: Bool = true, minimumEntries: Int = 0) throws -> Self {
        guard schemaVersion == 1, Set(networks.keys) == Set(["clearnet", "tor", "i2p"]) else { throw Invalid.schema }
        guard let observed = Self.day(date) else { throw Invalid.date }
        let age = Int(floor(now.timeIntervalSince1970 / 86_400)) - observed
        guard age >= 0 else { throw Invalid.future }
        guard !requireFresh || age <= Self.maximumAgeDays else { throw Invalid.expired }
        guard tip > 0 else { throw Invalid.height }
        var result = self
        for overlay in OverlayNetwork.allCases {
            result.networks[overlay.rawValue] = try validatedEntries(overlay, minimum: minimumEntries)
        }
        return result
    }

    private func validatedEntries(_ overlay: OverlayNetwork, minimum: Int) throws -> [Entry] {
        let entries = networks[overlay.rawValue] ?? []
        guard overlay == .i2p || entries.count >= minimum else { throw Invalid.thin }
        guard entries.count <= (overlay == .clearnet ? 65_536 : Self.overlayCap) else { throw Invalid.size }
        var seen = Set<PeerEndpoint>(), blocks = Set<String>()
        let canonical = try entries.map { input in
            let entry = try validatedEntry(input, overlay: overlay)
            guard seen.insert(entry.endpoint).inserted else { throw Invalid.duplicate }
            if overlay == .clearnet {
                guard let block = entry.endpoint.netblock else { throw Invalid.endpoint }
                guard blocks.insert(block).inserted else { throw Invalid.diversity }
            }
            return entry
        }
        return canonical.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    private func validatedEntry(_ input: Entry, overlay: OverlayNetwork) throws -> Entry {
        var entry = input
        guard entry.port > 0, entry.userAgent.utf8.count <= 256,
              !entry.userAgent.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let host = Self.canonicalHost(entry.host, overlay: overlay) else { throw Invalid.endpoint }
        guard Self.nearTip(entry.startHeight, tip: tip) else { throw Invalid.height }
        guard overlay != .clearnet || entry.port == 8333 else { throw Invalid.endpoint }
        entry.host = host
        return entry
    }

    public static func nearTip(_ height: Int32, tip: Int32) -> Bool {
        height >= 0 && tip > 0 && abs(Int64(height) - Int64(tip)) <= 100
    }

    /// Numeric public clearnet only. Collapse mapped IPv4 and IPv6 text aliases
    /// before deduplication and diversity; never invoke DNS here.
    public static func canonicalHost(_ text: String, overlay: OverlayNetwork) -> String? {
        guard text.utf8.count <= 255, text == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let host = text.lowercased()
        if overlay != .clearnet { return canonicalOverlay(host, overlay: overlay) }
        return canonicalIP(host)
    }

    private static func canonicalOverlay(_ host: String, overlay: OverlayNetwork) -> String? {
            let suffix = overlay == .tor ? ".onion" : ".b32.i2p"
            guard host.hasSuffix(suffix) else { return nil }
            let label = String(host.dropLast(suffix.count))
            guard let bytes = decodeBase32(label) else { return nil }
            if overlay == .tor {
                guard label.count == 56, bytes.count == 35, bytes[34] == 3 else { return nil }
                let checksum = OnionChecksum.hash(Array(".onion checksum".utf8) + Array(bytes.prefix(32)) + [3])
                guard bytes[32] == checksum[0], bytes[33] == checksum[1] else { return nil }
            } else {
                guard label.count == 52, bytes.count == 32 else { return nil }
            }
            return host
    }

    private static func canonicalIP(_ host: String) -> String? {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            guard publicV4(bytes) else { return nil }
            return bytes.map(String.init).joined(separator: ".")
        }
        var v6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            let mapped = Array(bytes.suffix(4))
            return publicV4(mapped) ? mapped.map(String.init).joined(separator: ".") : nil
        }
        // Accept global unicast 2000::/3, excluding special assignments,
        // documentation and transition mechanisms that can alias IPv4.
        guard bytes[0] & 0xe0 == 0x20,
              !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2),
              !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8),
              !(bytes[0] == 0x20 && bytes[1] == 0x02),
              !(bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] < 0x10) else { return nil }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &output, socklen_t(output.count)) != nil else { return nil }
        return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func publicV4(_ b: [UInt8]) -> Bool {
        guard ![0, 10, 127].contains(b[0]), b[0] < 224 else { return false }
        switch (b[0], b[1], b[2]) {
        case (100, 64...127, _), (169, 254, _), (172, 16...31, _),
             (192, 168, _), (192, 0, 0), (192, 0, 2), (192, 88, 99),
             (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
        default: return true
        }
    }

    private static func decodeBase32(_ text: String) -> [UInt8]? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var buffer: UInt32 = 0, bits = 0
        var result: [UInt8] = []
        for ch in text.utf8 {
            guard let value = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; result.append(UInt8((buffer >> bits) & 255)) }
        }
        guard buffer & ((1 << bits) - 1) == 0 else { return nil }
        return result
    }
}
