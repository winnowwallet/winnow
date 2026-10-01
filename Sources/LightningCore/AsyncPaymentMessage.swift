import Foundation

/// Pinned LDK async protocol messages carried inside BOLT4 onion messages.
/// The empty messages still encode a zero-length, BigSize-prefixed TLV stream.
/// Authentication and idempotency belong to the receiver's persisted context.
public enum AsyncPaymentMessage: Sendable {
    case offerPathsRequest(slot: UInt16)
    case offerPaths([BlindedPath], expiry: UInt64?)
    case serve(StaticInvoice, forwardRequest: BlindedPath)
    case persisted
    case held
    case release

    public init(record: LightningWire.TLV) throws {
        var envelope = LightningWire.Reader(record.value)
        let length = try envelope.bigSize()
        guard length == UInt64(envelope.remaining) else { throw LightningError.invalidMessage }
        var body = LightningWire.Reader(try envelope.take(Int(length)))
        let fields = try body.tlvs(known: [0, 2])
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.type, $0.value) })
        switch record.type {
        case 75540:
            guard let value = values[0], values[2] == nil else { throw LightningError.invalidMessage }
            var slot = LightningWire.Reader(value); self = .offerPathsRequest(slot: try slot.u16()); try slot.requireEnd()
        case 75542:
            guard let paths = values[0] else { throw LightningError.invalidMessage }
            let expiry = try values[2].map { bytes in
                var reader = LightningWire.Reader(bytes); let expiry = try reader.u64(); try reader.requireEnd(); return expiry
            }
            self = try .offerPaths(BlindedPath.decodeList(paths), expiry: expiry)
        case 75544:
            guard let invoice = values[0], let path = values[2] else { throw LightningError.invalidMessage }
            var reader = LightningWire.Reader(path)
            self = try .serve(StaticInvoice(bytes: invoice), forwardRequest: BlindedPath(reader: &reader)); try reader.requireEnd()
        case 75546, 72, 74:
            guard fields.allSatisfy({ $0.type % 2 == 1 }) else { throw LightningError.invalidMessage }
            self = record.type == 75546 ? .persisted : (record.type == 72 ? .held : .release)
        default: throw LightningError.invalidMessage
        }
    }
    public func record() throws -> LightningWire.TLV {
        let type: UInt64
        var fields: [LightningWire.TLV] = []
        switch self {
        case .offerPathsRequest(let slot):
            type = 75540; var writer = LightningWire.Writer(); writer.u16(slot); fields = [.init(type: 0, value: writer.data)]
        case .offerPaths(let paths, let expiry):
            type = 75542
            guard !paths.isEmpty else { throw LightningError.invalidMessage }
            fields = [try .init(type: 0, value: paths.map { try $0.encoded() }.reduce(Data(), +))]
            if let expiry { var writer = LightningWire.Writer(); writer.u64(expiry); fields.append(.init(type: 2, value: writer.data)) }
        case .serve(let invoice, let path):
            type = 75544; fields = try [.init(type: 0, value: invoice.bytes), .init(type: 2, value: path.encoded())]
        case .persisted: type = 75546
        case .held: type = 72
        case .release: type = 74
        }
        let body = try Bolt12Encoding.serialize(fields)
        var writer = LightningWire.Writer(); writer.bigSize(UInt64(body.count)); writer.append(body)
        return .init(type: type, value: writer.data)
    }
}

struct HTLCReleasePath: Sendable, Codable, Equatable {
    let id: UInt64
    let path: BlindedPath
    static func decode(_ bytes: Data) throws -> [HTLCReleasePath] {
        var reader = LightningWire.Reader(bytes), result: [HTLCReleasePath] = []
        while reader.remaining > 0 {
            guard result.count < 483 else { throw LightningError.invalidMessage }
            let id = try reader.u64(), path = try BlindedPath(reader: &reader)
            guard !result.contains(where: { $0.id == id }) else { throw LightningError.invalidMessage }
            result.append(.init(id: id, path: path))
        }
        return result
    }
}
