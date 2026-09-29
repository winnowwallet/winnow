import Foundation
import WalletCore

/// The transport is an untrusted source of proof records. Every delegation,
/// alias and final TXT signature is checked locally against pinned root DSs.
actor DNSSECValidator {
    typealias Fetch = @Sendable (String, UInt16) async throws -> [DNSSECWire.Record]
    struct Keys { let values: [DNSSECSignature.Key], ttl: UInt64 }
    var records: [DNSSECWire.Record]
    var cachedKeys: [String: Keys] = [:]
    var fetching = Set<String>()
    var queryCount = 0
    let now: UInt64, fetch: Fetch?, trustAnchors: [Data]
    var ttl = UInt64.max
    // IANA root-anchors.xml, active 2017 and prepublished 2024 KSK (2026 rollover).
    static let rootDS = [
        "4f660802e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d",
        "97280802683d2d0acb8c9b712a1948b27f741219298d0a450d612c483af444a4c0fb2b16"
    ].compactMap(Data.init(hex:))
    init(records: [DNSSECWire.Record] = [], now: UInt64, fetch: Fetch? = nil, trustAnchors: [Data] = rootDS) {
        self.records = records; self.now = now; self.fetch = fetch; self.trustAnchors = trustAnchors
    }

    func txt(name: String) async throws -> ([Data], UInt64) {
        var owner = name.lowercased(), seen = Set<String>()
        for _ in 0..<16 {
            guard seen.insert(owner).inserted else { throw DNSSECError.malformed }
            try await load(owner, type: 16)
            let txt = selected(owner, type: 16)
            if !txt.isEmpty { try await validate(txt); return (try txt.map(Self.txtData), ttl) }
            if let alias = signedAlias(owner) {
                owner = try await aliasTarget(alias); continue
            }
            if let alias = dname(owner) {
                owner = String(owner.dropLast(alias.name.count)) + (try await aliasTarget(alias))
                _ = try DNSSECWire.nameData(owner); continue
            }
            throw DNSSECError.unavailable
        }
        throw DNSSECError.malformed
    }
    private func aliasTarget(_ alias: DNSSECWire.Record) async throws -> String {
        let values = selected(alias.name, type: alias.type)
        guard values.count == 1 else { throw DNSSECError.ambiguous }
        try await validate(values); return try Self.target(alias)
    }
    private func signedAlias(_ owner: String) -> DNSSECWire.Record? {
        guard let alias = selected(owner, type: 5).first, !signatures(owner, type: 5).isEmpty else { return nil }; return alias
    }
    private func dname(_ owner: String) -> DNSSECWire.Record? {
        records.filter { $0.type == 39 && $0.dnsClass == 1 && $0.name != owner && DNSSECWire.subdomain(owner, of: $0.name) }
            .max { $0.name.count < $1.name.count }
    }
    private static func target(_ record: DNSSECWire.Record) throws -> String {
        var reader = DNSSECWire.Reader(record.data)
        let target = try reader.name(); guard reader.offset == reader.bytes.count else { throw DNSSECError.malformed }; return target
    }
    private static func txtData(_ record: DNSSECWire.Record) throws -> Data {
        var reader = DNSSECWire.Reader(record.data), result = Data()
        while reader.offset < reader.bytes.count { let count = try reader.u8(); result.append(try reader.take(Int(count))) }
        return result
    }
    func verifiedZones() -> [String] { Array(cachedKeys.keys) }
    private func load(_ name: String, type: UInt16) async throws {
        if !selected(name, type: type).isEmpty || type == 16 && (signedAlias(name) != nil || dname(name) != nil) { return }
        guard let fetch, queryCount < 64 else { throw DNSSECError.unavailable }
        queryCount += 1
        let received = try await fetch(name, type)
        guard records.count + received.count <= 4096 else { throw DNSSECError.malformed }
        for record in received where !records.contains(record) { records.append(record) }
    }
    func selected(_ name: String, type: UInt16) -> [DNSSECWire.Record] {
        var result: [Data: DNSSECWire.Record] = [:]
        for record in records where record.name == name && record.type == type && record.dnsClass == 1 {
            if let old = result[record.data], old.ttl <= record.ttl { continue }
            result[record.data] = record
        }
        return Array(result.values)
    }
    private func signatures(_ owner: String, type: UInt16) -> [DNSSECSignature.Signature] {
        selected(owner, type: 46).compactMap { try? DNSSECSignature.Signature($0.data) }.filter { $0.covered == type }
    }
    func validate(_ values: [DNSSECWire.Record]) async throws {
        guard let first = values.first else { throw DNSSECError.unauthenticated }
        for signature in signatures(first.name, type: first.type) where DNSSECWire.subdomain(first.name, of: signature.signer) {
            do {
                let keys = try await keys(signature.signer)
                let lifetime = try verify(values, signature: signature, keys: keys.values)
                try await validateWildcard(owner: first.name, signature: signature)
                ttl = min(ttl, lifetime, keys.ttl); return
            } catch { continue }
        }
        throw DNSSECError.unauthenticated
    }
    private func verify(_ values: [DNSSECWire.Record], signature: DNSSECSignature.Signature, keys: [DNSSECSignature.Key]) throws -> UInt64 {
        for key in keys where key.tag == signature.tag && key.algorithm == signature.algorithm {
            if let ttl = try? DNSSECSignature.verify(signature, key: key, records: values, now: now) { return ttl }
        }
        throw DNSSECError.unauthenticated
    }
    private func keys(_ zone: String) async throws -> Keys {
        if let saved = cachedKeys[zone] { return saved }
        guard fetching.insert(zone).inserted, fetching.count <= 32 else { throw DNSSECError.malformed }
        defer { fetching.remove(zone) }
        try await load(zone, type: 48)
        let records = selected(zone, type: 48), keys = records.compactMap { try? DNSSECSignature.Key($0.data) }
        let delegates = try await delegates(zone)
        let trusted = try keys.filter { key in try delegates.values.contains { try DNSSECSignature.matchesDS($0, key: key, zone: zone) } }
        guard !trusted.isEmpty else { throw DNSSECError.unauthenticated }
        for signature in signatures(zone, type: 48) where signature.signer == zone {
            if let lifetime = try? verify(records, signature: signature, keys: trusted) {
                let result = Keys(values: keys, ttl: min(lifetime, delegates.ttl)); cachedKeys[zone] = result; return result
            }
        }
        throw DNSSECError.unauthenticated
    }
    private func delegates(_ zone: String) async throws -> (values: [Data], ttl: UInt64) {
        if zone == "." { return (trustAnchors, .max) }
        try await load(zone, type: 43)
        let values = selected(zone, type: 43)
        guard !values.isEmpty else { throw DNSSECError.unauthenticated }
        for signature in signatures(zone, type: 43) where signature.signer != zone && DNSSECWire.subdomain(zone, of: signature.signer) {
            do {
                let parent = try await keys(signature.signer)
                let lifetime = try verify(values, signature: signature, keys: parent.values)
                return (values.map(\.data), min(lifetime, parent.ttl))
            } catch { continue }
        }
        throw DNSSECError.unauthenticated
    }
}
