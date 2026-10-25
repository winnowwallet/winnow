import CryptoKit
import Foundation

public enum PaymentURIError: Error, Equatable {
    case notABitcoinURI
    case missingAddress
    case invalidAmount
    case unsupportedRequiredParameter(String)
    case invalidPayjoinEndpoint(String)
    case duplicateParameter(String)
}

/// A BIP 21 payment URI as the wallet reads it: the address, an optional
/// amount in sats, label and message, and — when the receiver offers
/// payjoin — the BIP 77 session parameters carried in `pj`. Unknown
/// parameters are ignored as BIP 21 asks; unknown `req-` parameters refuse
/// the URI. `req-pj` makes payjoin mandatory.
///
/// Exercised by `PayjoinURITests`.
public struct PaymentURI: Equatable, Sendable {
    public var address: String
    public var amountSats: Int64?
    public var label: String?
    public var message: String?
    public var payjoin: PayjoinParameters?
    /// `req-pj`: the receiver insists on payjoin.
    public var payjoinRequired = false
    /// `pjos=0` disables payment output substitution (BIP 78). The wallet
    /// disables it regardless; this records what the receiver said.
    public var outputSubstitutionAllowed = true

    /// Whether `text` even looks like a payment URI, before parsing it.
    public static func looksLikeURI(_ text: String) -> Bool {
        text.lowercased().hasPrefix("bitcoin:")
    }

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"), trimmed[..<colon].lowercased() == "bitcoin" else {
            throw PaymentURIError.notABitcoinURI
        }
        let rest = trimmed[trimmed.index(after: colon)...]
        let question = rest.firstIndex(of: "?")
        address = String(rest[..<(question ?? rest.endIndex)])
        guard !address.isEmpty else { throw PaymentURIError.missingAddress }
        guard let question else { return }
        var seen: Set<String> = []
        for pair in rest[rest.index(after: question)...].split(separator: "&") {
            let (rawKey, rawValue) = Self.split(pair)
            let key = rawKey.lowercased()
            guard !seen.contains(key) else { throw PaymentURIError.duplicateParameter(key) }
            seen.insert(key)
            try apply(key: key, value: Self.percentDecoded(rawValue))
        }
    }

    private static func split(_ pair: Substring) -> (String, String) {
        guard let equals = pair.firstIndex(of: "=") else { return (String(pair), "") }
        return (String(pair[..<equals]), String(pair[pair.index(after: equals)...]))
    }

    private static func percentDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private mutating func apply(key: String, value: String) throws {
        switch key {
        case "amount": amountSats = try Self.sats(fromBTC: value)
        case "label": label = value
        case "message": message = value
        case "pj", "req-pj":
            payjoin = try PayjoinParameters(endpoint: value)
            if key == "req-pj" { payjoinRequired = true }
        case "pjos": outputSubstitutionAllowed = value != "0"
        default:
            if key.hasPrefix("req-") { throw PaymentURIError.unsupportedRequiredParameter(key) }
        }
    }

    /// A decimal BTC amount (BIP 21: "X.Y" with at most eight decimals, no
    /// exponent) in satoshis, within the money supply.
    static func sats(fromBTC text: String) throws -> Int64 {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), !text.isEmpty else { throw PaymentURIError.invalidAmount }
        let whole = parts[0]
        let fraction = parts.count == 2 ? parts[1] : ""
        guard (whole.isEmpty || whole.allSatisfy(\.isASCIIDigit)), fraction.allSatisfy(\.isASCIIDigit),
              fraction.count <= 8, !(whole.isEmpty && fraction.isEmpty)
        else { throw PaymentURIError.invalidAmount }
        let padded = fraction + String(repeating: "0", count: 8 - fraction.count)
        guard let btc = Int64(whole.isEmpty ? "0" : String(whole)), let sub = Int64(padded),
              btc <= 21_000_000 else { throw PaymentURIError.invalidAmount }
        let sats = btc * 100_000_000 + sub
        guard sats <= 2_100_000_000_000_000 else { throw PaymentURIError.invalidAmount }
        return sats
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The BIP 77 session a receiver put in its `pj` URL: the directory, the
/// receiver's mailbox, its HPKE key, the directory's OHTTP key and the
/// session expiry. Parsed from the uppercase URL with its `%23`-escaped
/// fragment of `EX1…`, `OH1…` and `RK1…` parameters, separated by `-` (or
/// `+`, which earlier drafts used and public directories still emit).
public struct PayjoinParameters: Equatable, Sendable {
    /// `scheme://host[:port]` of the directory.
    public var directory: URL
    /// The receiver mailbox's short ID, the last path component, uppercase.
    public var mailboxID: String
    /// The receiver's HPKE public key, 33-byte compressed.
    public var receiverKey: Data
    public var ohttpKeyConfig: OHTTP.KeyConfig
    public var expiry: Date

    public init(directory: URL, mailboxID: String, receiverKey: Data, ohttpKeyConfig: OHTTP.KeyConfig, expiry: Date) {
        self.directory = directory
        self.mailboxID = mailboxID
        self.receiverKey = receiverKey
        self.ohttpKeyConfig = ohttpKeyConfig
        self.expiry = expiry
    }

    /// The receiver's mailbox URL, the OHTTP target resource.
    public var mailboxURL: URL { directory.appending(path: mailboxID) }

    /// A BIP 77 mailbox for `shortID` on this directory.
    public func mailboxURL(shortID: String) -> URL { directory.appending(path: shortID) }

    public init(endpoint: String) throws {
        guard let hash = endpoint.firstIndex(of: "#") else { throw PaymentURIError.invalidPayjoinEndpoint("no fragment") }
        let base = String(endpoint[..<hash])
        let fragment = String(endpoint[endpoint.index(after: hash)...])
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(), let host = url.host,
              scheme == "https" || scheme == "http", url.query == nil, url.user == nil
        else { throw PaymentURIError.invalidPayjoinEndpoint("url") }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, let id = components.first, id.count == 13 else {
            throw PaymentURIError.invalidPayjoinEndpoint("mailbox path")
        }
        mailboxID = id.uppercased()
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host.lowercased()
        origin.port = url.port
        origin.path = "/"
        guard let directoryURL = origin.url else { throw PaymentURIError.invalidPayjoinEndpoint("origin") }
        directory = directoryURL
        let parameters = try Self.fragmentParameters(fragment)
        guard let rk = parameters["RK"], rk.count == 33, rk.first == 0x02 || rk.first == 0x03 else {
            throw PaymentURIError.invalidPayjoinEndpoint("RK")
        }
        receiverKey = rk
        guard let oh = parameters["OH"] else { throw PaymentURIError.invalidPayjoinEndpoint("OH") }
        ohttpKeyConfig = try Self.keyConfig(bip77: oh)
        guard let ex = parameters["EX"], ex.count == 4 else { throw PaymentURIError.invalidPayjoinEndpoint("EX") }
        let seconds = ex.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        expiry = Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// `KEY1VALUE` parameters: bech32 character set, no checksum, uppercase.
    static func fragmentParameters(_ fragment: String) throws -> [String: Data] {
        guard fragment.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "-" || $0 == "+") }) else {
            throw PaymentURIError.invalidPayjoinEndpoint("fragment characters")
        }
        let separator: Character
        switch (fragment.contains("-"), fragment.contains("+")) {
        case (true, true): throw PaymentURIError.invalidPayjoinEndpoint("fragment separators")
        case (false, true): separator = "+"
        default: separator = "-"
        }
        var parameters: [String: Data] = [:]
        for part in fragment.split(separator: separator) {
            guard let (hrp, bytes) = try? Bech32.decodeWithoutChecksum(String(part)) else {
                throw PaymentURIError.invalidPayjoinEndpoint("fragment parameter")
            }
            guard parameters[hrp.uppercased()] == nil else { throw PaymentURIError.invalidPayjoinEndpoint("repeated \(hrp)") }
            parameters[hrp.uppercased()] = Data(bytes)
        }
        return parameters
    }

    /// BIP 77's `OH` form of an OHTTP key configuration: the key id and the
    /// gateway's compressed key; KEM, KDF and AEAD are fixed by the BIP.
    public static func keyConfig(bip77 bytes: Data) throws -> OHTTP.KeyConfig {
        guard bytes.count == 34 else { throw PaymentURIError.invalidPayjoinEndpoint("OH length") }
        let compressed = bytes.dropFirst()
        guard let key = try? HPKE.Secp256k1.publicKey(compressed: Data(compressed)) else {
            throw PaymentURIError.invalidPayjoinEndpoint("OH key")
        }
        return OHTTP.KeyConfig(keyID: bytes[bytes.startIndex], kemID: HPKE.Secp256k1.id,
                               publicKey: HPKE.Secp256k1.serialize(key),
                               symmetricAlgorithms: [.init(kdfID: HPKE.kdfID, aeadID: HPKE.ChaChaPolyAEAD.id)])
    }

    /// The inverse of `keyConfig(bip77:)`, for receivers and tests.
    public static func bip77Bytes(of config: OHTTP.KeyConfig) throws -> Data {
        let key = try HPKE.Secp256k1.deserialize(config.publicKey)
        return Data([config.keyID]) + HPKE.Secp256k1.compressed(key)
    }

    /// The `pj` value a receiver publishes: the mailbox URL, uppercase, with
    /// the fragment parameters in lexicographical order.
    public var endpoint: String {
        let ex = withUnsafeBytes(of: UInt32(expiry.timeIntervalSince1970).littleEndian) { Data($0) }
        let oh = (try? Self.bip77Bytes(of: ohttpKeyConfig)) ?? Data()
        let fragment = [
            Bech32.encodeWithoutChecksum(hrp: "EX", data: Array(ex)),
            Bech32.encodeWithoutChecksum(hrp: "OH", data: Array(oh)),
            Bech32.encodeWithoutChecksum(hrp: "RK", data: Array(receiverKey)),
        ].joined(separator: "-")
        return mailboxURL.absoluteString.uppercased() + "#" + fragment
    }

    /// `endpoint` as it sits inside a BIP 21 URI, its `#` percent-encoded.
    public var queryValue: String { endpoint.replacingOccurrences(of: "#", with: "%23") }
}

/// BIP 77 mailbox identifiers: SHA-256 of a 33-byte compressed key,
/// truncated to 8 bytes, in the bech32 character set without HRP, separator
/// or checksum, uppercase.
public enum PayjoinShortID {
    public static func derive(compressedKey: Data) -> String {
        let digest = CryptoKit.SHA256.hash(data: compressedKey)
        return Bech32.encodeWithoutChecksum(hrp: "", data: Array(digest.prefix(8)))
    }
}

extension Bech32 {
    /// Uppercase bech32 data part (8→5 bits, zero padded) with no checksum;
    /// an empty HRP gives the bare data characters.
    static func encodeWithoutChecksum(hrp: String, data: [UInt8]) -> String {
        let values = (try? SegwitAddress.convertBits(data, from: 8, to: 5, pad: true)) ?? []
        let body = String(bytes: values.map { charsetBytes[Int($0)] }, encoding: .utf8) ?? ""
        return (hrp.isEmpty ? body : hrp + "1" + body).uppercased()
    }

    /// The HRP and bytes of a checksum-less bech32 string.
    static func decodeWithoutChecksum(_ string: String) throws -> (hrp: String, bytes: [UInt8]) {
        let lowered = string.lowercased()
        guard let separator = lowered.firstIndex(of: "1") else { throw Bech32Error.missingSeparator }
        let hrp = String(lowered[..<separator])
        guard !hrp.isEmpty else { throw Bech32Error.emptyHRP }
        var values: [UInt8] = []
        for char in lowered[lowered.index(after: separator)...].utf8 {
            guard let value = charsetBytes.firstIndex(of: char) else { throw Bech32Error.invalidCharacter }
            values.append(UInt8(value))
        }
        return (hrp, try SegwitAddress.convertBits(values, from: 5, to: 8, pad: false))
    }

    static let charsetBytes = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
}
