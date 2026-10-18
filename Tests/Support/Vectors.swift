import WalletCore
import Foundation

/// Why a bundled test vector could not be loaded or read.
public enum VectorError: Error {
    case missingFile(String)
    case badHex(String)
    case malformed(String)
}

/// Bundled test-vector files. The bundle is explicit because every test
/// target ships its own `Vectors/` directory: a caller passes `Bundle.module`.
public enum Vectors {
    /// The raw bytes of `name` under `subdirectory` in `bundle`.
    public static func data(_ name: String, in bundle: Bundle,
                            subdirectory: String = "Vectors") throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: subdirectory) else {
            throw VectorError.missingFile(name)
        }
        return try Data(contentsOf: url)
    }

    /// `data(_:in:subdirectory:)` read as UTF-8.
    public static func string(_ name: String, in bundle: Bundle,
                              subdirectory: String = "Vectors") throws -> String {
        String(decoding: try data(name, in: bundle, subdirectory: subdirectory), as: UTF8.self)
    }

    /// A JSON vector file decoded into `type`.
    public static func decode<T: Decodable>(_ type: T.Type, _ name: String, in bundle: Bundle,
                                            subdirectory: String = "Vectors") throws -> T {
        try JSONDecoder().decode(type, from: data(name, in: bundle, subdirectory: subdirectory))
    }

    /// A JSON vector file as the loosely typed object graph `JSONSerialization`
    /// produces, for the vector schemas that mix types inside one array.
    public static func json(_ name: String, in bundle: Bundle,
                            subdirectory: String = "Vectors") throws -> Any {
        try JSONSerialization.jsonObject(with: data(name, in: bundle, subdirectory: subdirectory))
    }
}

/// Extracts the contents of every <tt>...</tt> tag in a line of a BIP mediawiki doc.
public func ttTags(in line: String) -> [String] {
    line.components(separatedBy: "<tt>").dropFirst().compactMap { chunk in
        guard let end = chunk.range(of: "</tt>") else { return nil }
        return String(chunk[..<end.lowerBound])
    }
}

// MARK: - Loaders shared by more than one target

/// One row of the BIP158 testnet vector file (`bip158-testnet-19.json`):
/// hashes in internal byte order, the block both raw and decoded.
public struct BIP158Vector {
    public let height: Int
    public let blockHash: Data
    public let rawBlock: Data
    public let block: Block
    public let prevScripts: [Data]
    public let previousHeader: Data
    public let filter: Data
    public let header: Data
}

/// The valid descriptors (each with its expected scriptPubKeys) and the
/// invalid ones of a BIP whose "Test Vectors" section is written the BIP387
/// / BIP390 way: `* <tt>descriptor</tt>` bullets with `** <tt>script</tt>`
/// sub-bullets, then an "Invalid descriptors" list.
public struct DescriptorVectors {
    public var valid: [(descriptor: String, scripts: [String])] = []
    public var invalid: [String] = []
}

extension Vectors {
    /// The BIP158 testnet vectors. The JSON carries display-order hashes;
    /// every hash here is reversed into internal order.
    public static func bip158(in bundle: Bundle) throws -> [BIP158Vector] {
        let json = try Vectors.json("bip158-testnet-19.json", in: bundle) as! [Any]
        return try json.dropFirst().map { entry in
            let row = entry as! [Any]
            guard let block = Data(hex: row[2] as! String),
                  let filter = Data(hex: row[5] as! String),
                  let header = Data(hex: row[6] as! String),
                  let blockHash = Data(hex: row[1] as! String),
                  let previousHeader = Data(hex: row[4] as! String)
            else { throw VectorError.badHex(String(describing: row[0])) }
            let prevScripts = (row[3] as! [String]).map { hex -> Data in
                // Empty prev output scripts occur (spent outputs with empty scriptPubKey).
                hex.isEmpty ? Data() : Data(hex: hex)!
            }
            return BIP158Vector(height: row[0] as! Int, blockHash: Data(blockHash.reversed()),
                                rawBlock: block, block: try Block.decode(block),
                                prevScripts: prevScripts,
                                previousHeader: Data(previousHeader.reversed()), filter: filter,
                                header: Data(header.reversed()))
        }
    }

    /// The descriptor vector blocks of a BIP387/BIP390-style mediawiki doc.
    public static func descriptorVectors(_ name: String, in bundle: Bundle) throws -> DescriptorVectors {
        let text = try string(name, in: bundle)
        var vectors = DescriptorVectors()
        var section = 0 // 0 = before, 1 = valid, 2 = invalid
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("==Test Vectors==") { section = 1; continue }
            if line.hasPrefix("Invalid descriptors") { section = 2; continue }
            if line.hasPrefix("==Backwards Compatibility==") { section = 0 }
            let tags = ttTags(in: line)
            guard !tags.isEmpty else { continue }
            switch section {
            case 1 where line.hasPrefix("* <tt>"):
                vectors.valid.append((tags[0], []))
            case 1 where line.hasPrefix("** <tt>"):
                vectors.valid[vectors.valid.count - 1].scripts.append(tags[0])
            case 2 where line.hasPrefix("* "):
                vectors.invalid.append(tags.last!)
            default:
                break
            }
        }
        return vectors
    }
}

// MARK: - Bitcoin Core vectors extracted from its test sources

/// One `Test(...)` row of Core's `src/test/miniscript_tests.cpp`: the
/// expression, its `TESTMODE_*` flags, and the script bytes Core expects in
/// each context where the row states them.
public struct CoreMiniscriptVector: Decodable, Sendable {
    public let miniscript: String
    public let modes: [String]
    public let p2wshScript: String?
    public let tapscript: String?
    public let comment: String?

    enum CodingKeys: String, CodingKey {
        case miniscript, modes, tapscript, comment
        case p2wshScript = "p2wsh_script"
    }

    /// Whether Core expects the expression to parse as a valid script in `context`.
    public func isValid(in context: Miniscript.Context) -> Bool {
        !modes.contains("TESTMODE_INVALID")
            && !(context == .p2wsh && modes.contains("TESTMODE_P2WSH_INVALID"))
            && !(context == .tapscript && modes.contains("TESTMODE_TAPSCRIPT_INVALID"))
    }

    /// The script bytes Core states for `context`, if the row gives them.
    public func expectedScript(in context: Miniscript.Context) -> String? {
        context == .p2wsh ? p2wshScript : tapscript
    }
}

/// One `Check(...)` row of Core's `src/test/descriptor_tests.cpp`: the
/// descriptor with private keys, with public keys, normalized, its flags, and
/// the scriptPubKeys expected at index 0, 1, 2 (one for an unranged descriptor).
public struct CoreDescriptorVector: Decodable, Sendable {
    public let privateText: String
    public let publicText: String
    public let normalized: String
    public let flags: [String]
    public let scriptPubKeys: [String]

    enum CodingKeys: String, CodingKey {
        case normalized, flags, scriptPubKeys
        case privateText = "private"
        case publicText = "public"
    }
}

/// One `CheckUnparsable(...)` row: a descriptor Core refuses and its reason.
public struct CoreUnparsableDescriptor: Decodable, Sendable {
    public let privateText: String
    public let publicText: String
    public let error: String

    enum CodingKeys: String, CodingKey {
        case error
        case privateText = "private"
        case publicText = "public"
    }
}

public struct CoreDescriptorVectors: Decodable, Sendable {
    public let source: String
    public let vectors: [CoreDescriptorVector]
    public let unparsable: [CoreUnparsableDescriptor]
}

extension Vectors {
    /// Core's miniscript rows (`core-miniscript-v31.0.json`).
    public static func coreMiniscript(in bundle: Bundle) throws -> [CoreMiniscriptVector] {
        struct File: Decodable { let vectors: [CoreMiniscriptVector] }
        return try decode(File.self, "core-miniscript-v31.0.json", in: bundle).vectors
    }

    /// Core's descriptor rows for one top level (`core-taproot-descriptors-v31.0.json`,
    /// `core-wsh-descriptors-v31.0.json`).
    public static func coreDescriptors(_ name: String, in bundle: Bundle) throws -> CoreDescriptorVectors {
        try decode(CoreDescriptorVectors.self, name, in: bundle)
    }
}
