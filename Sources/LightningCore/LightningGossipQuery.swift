import Foundation

struct LightningGossipQuery: Sendable {
    var graph: LightningRoutingGraph
    let blocks: UInt32
    var ids = Set<UInt64>(), pending: [UInt64] = []
    var awaitingRange = true
    var previousFirst: UInt32?
    var receivedEnd: UInt64 = 0
    let startedAt: UInt64
    var lastProgress: UInt64
    var queried = 0
    init(chain: Data, height: UInt32, now: UInt64) throws {
        guard height < UInt32.max else { throw LightningError.invalidAmount }
        graph = LightningRoutingGraph(chain: chain); blocks = height + 1; lastProgress = now; startedAt = now
    }
    func range() throws -> LightningWire.Message {
        var w = LightningWire.Writer(); w.append(graph.chain); w.u32(0); w.u32(blocks)
        return try .init(type: 263, payload: w.data)
    }
    mutating func receiveRange(_ message: LightningWire.Message, now: UInt64) throws -> Bool {
        guard awaitingRange else { throw LightningError.invalidMessage }
        var r = LightningWire.Reader(message.payload); guard try r.take(32) == graph.chain else { throw LightningError.invalidHash }
        let first = try r.u32(), count = try r.u32(), complete = try r.u8(), length = try r.u16()
        var encoded = LightningWire.Reader(try r.take(Int(length)))
        guard try encoded.u8() == 0, encoded.remaining % 8 == 0, complete <= 1, count > 0,
              UInt64(first) + UInt64(count) <= UInt64(UInt32.max) + 1,
              (previousFirst.map({ first >= $0 && UInt64(first) <= receivedEnd }) ?? (first == 0)) else { throw LightningError.invalidMessage }
        try insertRangeIDs(&encoded, first: first, count: count)
        _ = try r.tlvs(known: [1, 3])
        guard ids.count <= LightningRoutingGraph.limit else { throw LightningError.invalidMessage }
        previousFirst = first; receivedEnd = max(receivedEnd, UInt64(first) + UInt64(count)); lastProgress = now
        if complete == 1 {
            guard receivedEnd >= UInt64(blocks) else { throw LightningError.invalidMessage }
            awaitingRange = false; pending = ids.sorted(); return true
        }
        return false
    }
    private mutating func insertRangeIDs(_ encoded: inout LightningWire.Reader, first: UInt32, count: UInt32) throws {
        var previous: UInt64?
        while encoded.remaining > 0 {
            let id = try encoded.u64()
            guard previous.map({ id > $0 }) ?? true,
                  id >> 40 >= UInt64(first), id >> 40 < UInt64(first) + UInt64(count) else { throw LightningError.invalidMessage }
            ids.insert(id)
            previous = id
        }
    }
    mutating func next() throws -> LightningWire.Message? {
        guard !pending.isEmpty else { return nil }
        let batch = Array(pending.prefix(2048)); pending.removeFirst(batch.count); queried += batch.count
        var w = LightningWire.Writer(), encoded = LightningWire.Writer(); encoded.u8(0)
        for id in batch { encoded.u64(id) }
        w.append(graph.chain); w.u16(UInt16(encoded.data.count)); w.append(encoded.data)
        // Request announcements and both updates. Node features are needed too.
        return try .init(type: 261, payload: w.data)
    }
    static func emptyResponse(_ message: LightningWire.Message) throws -> LightningWire.Message {
        var r = LightningWire.Reader(message.payload), w = LightningWire.Writer(); w.append(try r.take(32))
        if message.type == 261 { w.u8(0); return try .init(type: 262, payload: w.data) }
        w.u32(try r.u32()); let blocks = try r.u32(); guard blocks > 0 else { throw LightningError.invalidMessage }
        w.u32(blocks); w.u8(1); w.u16(1); w.u8(0)
        return try .init(type: 264, payload: w.data)
    }
}
