import Foundation
import Testing
@testable import WalletCore

struct CensusCatalogTests {
    let now = Date(timeIntervalSince1970: 1_789_300_800) // 2026-09-13 UTC
    let onion = "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion"
    func catalog(_ date: String = "2026-09-13") -> CensusCatalog {
        .init(date: date, tip: 900_000, networks: [
            "clearnet": [.init(host: "8.8.8.8", port: 8333, userAgent: "/Satoshi:30/", startHeight: 900_100)],
            "tor": [.init(host: onion, port: 8333, userAgent: "/Satoshi:30/", startHeight: 899_900)], "i2p": [],
        ])
    }
    @Test func datesAndSchema() throws {
        _ = try catalog().validated(now: now)
        _ = try catalog("2026-09-06").validated(now: now)
        #expect(throws: CensusCatalog.Invalid.expired) { try catalog("2026-09-05").validated(now: now) }
        #expect(throws: CensusCatalog.Invalid.future) { try catalog("2026-09-14").validated(now: now) }
        #expect(throws: CensusCatalog.Invalid.date) { try catalog("2026-02-30").validated(now: now) }
        var c = catalog(); c.schemaVersion = 2
        #expect(throws: CensusCatalog.Invalid.schema) { try c.validated(now: now) }
        #expect(CensusCatalog.day("0000-01-01") == nil)
        #expect(throws: CensusCatalog.Invalid.size) { try CensusCatalog.decode(Data(repeating: 0, count: CensusCatalog.maximumBytes + 1)) }
    }
    @Test func aThinListIsRefusedOnlyWhereAFloorApplies() throws {
        _ = try catalog().validated(now: now)
        #expect(throws: CensusCatalog.Invalid.thin) { try catalog().validated(now: now, minimumEntries: 2) }
        var c = catalog()
        c.networks["i2p"] = []
        _ = try c.validated(now: now, minimumEntries: 1) // I2P has no floor
        c.networks["tor"] = []
        #expect(throws: CensusCatalog.Invalid.thin) { try c.validated(now: now, minimumEntries: 1) }
    }
    @Test func extremeHeightsAndAliases() throws {
        #expect(!CensusCatalog.nearTip(.min, tip: .max))
        #expect(!CensusCatalog.nearTip(.max, tip: .min))
        #expect(!CensusCatalog.nearTip(900_101, tip: 900_000))
        #expect(CensusCatalog.canonicalHost("::ffff:8.8.8.8", overlay: .clearnet) == "8.8.8.8")
        #expect(CensusCatalog.canonicalHost("2606:4700:0000:0000:0000:0000:0000:1111", overlay: .clearnet) == "2606:4700::1111")
        var c = catalog()
        c.networks["clearnet"]!.append(.init(host: "::ffff:8.8.8.8", port: 8333, userAgent: "", startHeight: 900_000))
        #expect(throws: CensusCatalog.Invalid.duplicate) { try c.validated(now: now) }
        c.networks["clearnet"]![1].host = "8.8.4.4"
        #expect(throws: CensusCatalog.Invalid.diversity) { try c.validated(now: now) }
    }
    @Test func addressPolicies() {
        for host in ["127.0.0.1", "::ffff:127.0.0.1", "example.com", "192.0.2.1", "198.18.1.1",
                     "100.64.1.1", "2001:db8::1", "fe80::1", "fc00::1", "2002:0808:0808::1", "3fff::1"] {
            #expect(CensusCatalog.canonicalHost(host, overlay: .clearnet) == nil)
        }
        #expect(CensusCatalog.canonicalHost(onion.uppercased(), overlay: .tor) == onion)
        #expect(CensusCatalog.canonicalHost("a" + onion.dropFirst(), overlay: .tor) == nil)
        #expect(CensusCatalog.canonicalHost(onion, overlay: .i2p) == nil)
        #expect(CensusCatalog.canonicalHost(String(repeating: "a", count: 52) + ".b32.i2p", overlay: .i2p) != nil)
        #expect(CensusCatalog.canonicalHost("name.i2p", overlay: .i2p) == nil)
    }
    @Test func checksumKnownAnswers() {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(OnionChecksum.hash([])) == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
        #expect(hex(OnionChecksum.hash(Array("abc".utf8))) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    }
}
