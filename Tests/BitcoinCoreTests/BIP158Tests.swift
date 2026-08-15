import Foundation
import Testing
@testable import BitcoinCore

/// BIP158 test vectors (bip-0158/testnet-19.json): reconstruct basic filters
/// from block output scripts + previous output scripts, compare filter and header.
@Suite("BIP158")
struct BIP158Tests {
    struct Vector {
        let height: Int
        let blockHash: Data // internal byte order
        let block: Data
        let prevScripts: [Data]
        let previousHeader: Data // internal byte order
        let filter: Data
        let header: Data // internal byte order
    }

    static func vectors() throws -> [Vector] {
        let json = try JSONSerialization.jsonObject(with: vectorData("bip158-testnet-19.json")) as! [Any]
        return try json.dropFirst().map { entry in
            let row = entry as! [Any]
            guard let block = Data(hex: row[2] as! String),
                  let filter = Data(hex: row[5] as! String),
                  let header = Data(hex: row[6] as! String),
                  let blockHash = Data(hex: row[1] as! String),
                  let previousHeader = Data(hex: row[4] as! String)
            else { throw VectorError.badHex(String(describing: row[0])) }
            let prevScripts = try (row[3] as! [String]).map { hex -> Data in
                // Empty prev output scripts occur (spent outputs with empty scriptPubKey).
                hex.isEmpty ? Data() : Data(hex: hex)!
            }
            // JSON hashes are display (big-endian) order; internals are reversed.
            return Vector(height: row[0] as! Int, blockHash: Data(blockHash.reversed()),
                          block: block, prevScripts: prevScripts,
                          previousHeader: Data(previousHeader.reversed()), filter: filter,
                          header: Data(header.reversed()))
        }
    }

    @Test("filter construction matches vectors")
    func construction() throws {
        for vector in try Self.vectors() {
            // BIP158 basic filter items: previous output scripts plus every output
            // scriptPubKey, skipping empty and provably-unspendable (OP_RETURN) scripts.
            let items = (vector.prevScripts + (try blockOutputScripts(vector.block)))
                .filter { !$0.isEmpty && $0.first != 0x6A }
            let filter = try GCSFilter(items: items, key: vector.blockHash.prefix(16))
            #expect(filter.serialized == vector.filter, "height \(vector.height)")
        }
    }

    @Test("filter headers match vectors")
    func headers() throws {
        for vector in try Self.vectors() {
            let header = GCSFilter.filterHeader(vector.filter, previousHeader: vector.previousHeader)
            #expect(header == vector.header, "height \(vector.height)")
        }
    }

    @Test("constructed filters match their own items and reject strangers")
    func matching() throws {
        for vector in try Self.vectors() {
            let items = (vector.prevScripts + (try blockOutputScripts(vector.block)))
                .filter { !$0.isEmpty && $0.first != 0x6A }
            let filter = try GCSFilter(items: items, key: vector.blockHash.prefix(16))
            for item in Set(items) {
                #expect(filter.contains(item), "height \(vector.height)")
            }
            #expect(!filter.contains(Data([0xDE, 0xAD, 0xBE, 0xEF])))
            #expect(filter.containsAny(Array(items.prefix(1))) == !items.isEmpty)
        }
    }

    @Test("empty filter round-trips")
    func emptyFilter() throws {
        let filter = try GCSFilter(items: [], key: Data(repeating: 0, count: 16))
        #expect(filter.serialized == Data([0]))
        #expect(!filter.contains(Data([0x51])))
    }
}
