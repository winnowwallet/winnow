import Foundation
import Testing
@testable import WalletCore

struct CensusCatalogTests {
    let now = Date(timeIntervalSince1970: 1_789_300_800) // 2026-09-13 UTC
    /// The published shape: the census also lists `tor` and `i2p` nodes,
    /// which the wallet does not dial and validation drops.
    func catalog(_ date: String = "2026-09-13") -> CensusCatalog {
        .init(date: date, tip: 900_000, networks: [
            "clearnet": [.init(host: "8.8.8.8", port: 8333, userAgent: "/Satoshi:30/", startHeight: 900_100)],
            "tor": [.init(host: "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion", port: 8333,
                          userAgent: "/Satoshi:30/", startHeight: 899_900)],
            "i2p": [],
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
        c = catalog(); c.networks["clearnet"] = nil
        #expect(throws: CensusCatalog.Invalid.schema) { try c.validated(now: now) }
        #expect(CensusCatalog.day("0000-01-01") == nil)
        #expect(throws: CensusCatalog.Invalid.size) { try CensusCatalog.decode(Data(repeating: 0, count: CensusCatalog.maximumBytes + 1)) }
    }
    @Test func aThinListIsRefusedAndOtherNetworksAreDropped() throws {
        let validated = try catalog().validated(now: now)
        #expect(validated.networks.keys.sorted() == ["clearnet"], "only what the wallet dials survives validation")
        #expect(throws: CensusCatalog.Invalid.thin) { try catalog().validated(now: now, minimumEntries: 2) }
        var c = catalog()
        c.networks["tor"] = [.init(host: "not an onion", port: 0, userAgent: "", startHeight: -1)]
        _ = try c.validated(now: now, minimumEntries: 1) // an undialled list is never inspected
    }
    @Test func extremeHeightsAndAliases() throws {
        #expect(!CensusCatalog.nearTip(.min, tip: .max))
        #expect(!CensusCatalog.nearTip(.max, tip: .min))
        #expect(!CensusCatalog.nearTip(900_101, tip: 900_000))
        #expect(CensusCatalog.canonicalHost("::ffff:8.8.8.8") == "8.8.8.8")
        #expect(CensusCatalog.canonicalHost("2606:4700:0000:0000:0000:0000:0000:1111") == "2606:4700::1111")
        var c = catalog()
        c.networks["clearnet"]!.append(.init(host: "::ffff:8.8.8.8", port: 8333, userAgent: "", startHeight: 900_000))
        #expect(throws: CensusCatalog.Invalid.duplicate) { try c.validated(now: now) }
        c.networks["clearnet"]![1].host = "8.8.4.4"
        #expect(throws: CensusCatalog.Invalid.diversity) { try c.validated(now: now) }
    }
    @Test func addressPolicies() {
        for host in ["127.0.0.1", "::ffff:127.0.0.1", "example.com", "192.0.2.1", "198.18.1.1",
                     "100.64.1.1", "2001:db8::1", "fe80::1", "fc00::1", "2002:0808:0808::1", "3fff::1",
                     "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion", "name.b32.i2p"] {
            #expect(CensusCatalog.canonicalHost(host) == nil)
        }
        var c = catalog()
        c.networks["clearnet"]![0].host = "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion"
        #expect(throws: CensusCatalog.Invalid.endpoint) { try c.validated(now: now) }
    }
}
