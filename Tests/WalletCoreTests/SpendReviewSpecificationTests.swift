import CryptoKit
import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// `MultisigAccount.reviewSpend` against the executable specification in
/// `Tools/Proofs/SpendReview` (Lean). Each vector names an account, its known
/// coins, a PSBT and the output coordinates by where their bytes come from,
/// with the review the specification gives. This suite makes the real bytes
/// (scripts, leaves and internal keys of a real 2-of-3 account) and requires
/// `reviewSpend` to show the same outputs, totals, fee and path, or to refuse
/// for the same reason at the same input or output. The fixture is generated,
/// never edited; `Tools/Proofs/SpendReview/README.md` has the command.
@Suite("Spend review against its specification")
struct SpendReviewSpecificationTests {
    /// The vectors run in this many slices, in parallel: each review
    /// derives keys on the native curve, which is slow in a debug build.
    static let slices = 8

    fileprivate static func vectors() throws -> [Vector] {
        try Vectors.decode(SpecificationFile.self, "spend-review-specification.json", in: .module).vectors
    }

    @Test("the fixture is the generated one and reaches every refusal the specification has")
    func coverage() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 1_506)
        #expect(vectors.map(\.id) == Array(vectors.indices))
        let refusals = Set(vectors.compactMap(\.expect.reject?.reason))
        #expect(refusals == Refusal.codes, "never refused for: \(Refusal.codes.subtracting(refusals).sorted())")
    }

    @Test("reviewSpend agrees with the Lean specification on every generated vector", arguments: 0 ..< slices)
    func agreesWithSpecification(slice: Int) throws {
        var accounts: [UInt32?: Renderer] = [:]
        var disagreements: [String] = []
        for vector in try Self.vectors() where vector.id % Self.slices == slice {
            let renderer = try accounts[vector.recovery] ?? Renderer(recovery: vector.recovery)
            accounts[vector.recovery] = renderer
            let actual: Outcome
            do {
                actual = .accepted(try renderer.account.reviewSpend(
                    try renderer.psbt(vector.psbt), knownUTXOs: try vector.known.map(renderer.coin),
                    ownedOutputCoordinates: vector.coords.map {
                        MultisigAccount.OutputCoordinate(choice: Int($0[0]), index: UInt32($0[1]))
                    },
                    chainTip: vector.tip))
            } catch {
                actual = .refused(Refusal(error))
            }
            if let problem = try renderer.disagreement(actual, expected: vector.expect) {
                disagreements.append("vector \(vector.id) (\(vector.notes.joined(separator: ", "))): \(problem)")
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.count) disagreements:\n\(disagreements.prefix(20).joined(separator: "\n"))")
    }
}

// MARK: - The fixture

private struct SpecificationFile: Decodable {
    var source: String
    var vectors: [Vector]
}

/// A field that is present, absent, or present with bytes that do not decode.
private enum Field<Value: Decodable>: Decodable {
    case value(Value)
    case absent
    case malformed

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .absent
        } else if let text = try? container.decode(String.self), text == "malformed" {
            self = .malformed
        } else {
            self = .value(try container.decode(Value.self))
        }
    }
}

private struct Vector: Decodable {
    struct Coin: Decodable {
        var txid: UInt64
        var vout: UInt32
        var amount: Int64
        var script: String
        var chain: Int
        var index: UInt32
        var height: UInt32
        var coinbase: Bool
    }

    struct Witness: Decodable {
        var amount: Int64
        var script: String
    }

    struct Input: Decodable {
        var txid: Field<UInt64>
        var vout: Field<UInt32>
        var sequence: Field<UInt32>
        var sighash: Field<UInt32>
        var witness: Field<Witness>
        var internalKey: String?
        var leaves: [String]
    }

    struct Output: Decodable {
        var amount: Field<Int64>
        var script: String?
    }

    struct Shape: Decodable {
        var version: Int32
        var inputs: [Input]
        var outputs: [Output]
    }

    struct Accepted: Decodable {
        struct Line: Decodable {
            var amount: Int64
            var script: String
            var owned: Bool

            init(from decoder: any Decoder) throws {
                var container = try decoder.unkeyedContainer()
                amount = try container.decode(Int64.self)
                script = try container.decode(String.self)
                owned = try container.decode(Bool.self)
            }
        }

        var outputs: [Line]
        var inputTotal: Int64
        var outputTotal: Int64
        var fee: Int64
        var path: String
    }

    struct Rejected: Decodable, Equatable {
        var reason: String
        var at: Int?
    }

    struct Expectation: Decodable {
        var accept: Accepted?
        var reject: Rejected?
    }

    var id: Int
    var notes: [String]
    var recovery: UInt32?
    var tip: UInt32
    var known: [Coin]
    var coords: [[Int64]]
    var psbt: Shape
    var expect: Expectation
}

private enum Outcome {
    case accepted(MultisigAccount.SpendReview)
    case refused(Refusal)
}

/// A refusal as the specification names it: a reason and, for one about an
/// input or output, its position from 0.
private struct Refusal: Equatable, CustomStringConvertible {
    var reason: String
    var at: Int?

    static let messages: [(fragment: String, code: String)] = [
        ("it has no inputs", "noInputs"),
        ("it has no outputs or more than 1,000", "outputCount"),
        ("transaction version", "txVersion"),
        ("has no complete outpoint", "incompleteOutpoint"),
        ("repeats an earlier outpoint", "repeatedOutpoint"),
        ("is not an available coin of this account", "unknownCoin"),
        ("has the wrong amount or locking script", "wrongAmountOrScript"),
        ("spends a coinbase that matures", "immatureCoinbase"),
        ("does not belong to this descriptor", "notThisDescriptor"),
        ("does not commit to every output", "sighash"),
        ("changes the spending policy", "policy"),
        ("unlocks for recovery only", "recoveryLocked"),
        ("input amounts exceed Bitcoin's supply", "inputSupply"),
        ("too many candidate account output paths", "candidates"),
        ("has an invalid amount or script", "invalidOutput"),
        ("output amounts exceed Bitcoin's supply", "outputSupply"),
        ("outputs exceed its known inputs", "outputsExceedInputs"),
        ("exceeds the 10% safety limit", "feeCeiling"),
    ]

    static let codes = Set(messages.map(\.code) + ["psbtField", "derivation"])

    init(_ error: any Error) {
        switch error {
        case let MultisigAccountError.invalidSpend(message):
            let code = Self.messages.first { message.contains($0.fragment) }?.code ?? "unrecognised: \(message)"
            let words = message.split(separator: " ")
            let position = words.count > 1 && ["input", "output"].contains(words[0]) ? Int(words[1]).map { $0 - 1 } : nil
            self.init(reason: code, at: position)
        case is PSBTError:
            self.init(reason: "psbtField", at: nil)
        case is BIP32Error, is DescriptorError:
            self.init(reason: "derivation", at: nil)
        default:
            self.init(reason: "unexpected: \(error)", at: nil)
        }
    }

    init(reason: String, at: Int?) {
        self.reason = reason
        self.at = at
    }

    var description: String { at.map { "\(reason) at \($0)" } ?? reason }
}

// MARK: - Bytes for the specification's names

/// One account (a 2-of-3 of the test keys, with or without a 1-of-3 recovery
/// leaf after `recovery` blocks) and the bytes behind every name a vector
/// uses: `a<choice>/<index>` scripts, `i…` internal keys, `s…`/`r…` leaves
/// and `f<tag>` foreign values that collide with nothing.
private final class Renderer {
    let account: MultisigAccount
    private var leafCache: [String: [MultisigAccount.Leaf]] = [:]
    private var scriptCache: [String: Data] = [:]

    init(recovery: UInt32?) throws {
        let signers = try TestKeys.masters().map { try TestKeys.keyExpression(master: $0) }
        let descriptor = try MultisigAccount.descriptor(
            threshold: 2, signers: signers,
            recovery: recovery.map { .fewerSigners(threshold: 1, blocks: $0) }, network: .signet)
        account = try MultisigAccount(descriptor: descriptor, network: .signet)
        #expect(account.recovery?.blocks == recovery)
    }

    static func digest(_ label: String) -> Data { Data(SHA256.hash(data: Data(label.utf8))) }

    static func txid(_ tag: UInt64) -> Data { digest("txid \(tag)") }

    /// "a0/3" → (0, 3).
    static func coordinate(_ name: String) throws -> (choice: Int, index: UInt32) {
        let parts = name.dropFirst().split(separator: "/")
        guard parts.count == 2, let choice = Int(parts[0]), let index = UInt32(parts[1]) else {
            throw VectorError.malformed(name)
        }
        return (choice, index)
    }

    static func tag(_ name: String) throws -> UInt64 {
        guard let tag = UInt64(name.dropFirst()) else { throw VectorError.malformed(name) }
        return tag
    }

    func leaves(_ name: String) throws -> [MultisigAccount.Leaf] {
        let (choice, index) = try Self.coordinate(name)
        let key = "\(choice)/\(index)"
        if let cached = leafCache[key] { return cached }
        let leaves = try account.leaves(choice: choice, index: index)
        leafCache[key] = leaves
        return leaves
    }

    func script(_ name: String) throws -> Data {
        if let cached = scriptCache[name] { return cached }
        let bytes: Data
        switch name.first {
        case "e": bytes = Data()
        case "f": bytes = Data([0x51, 0x20]) + Self.digest("script \(try Self.tag(name))")
        case "a":
            let (choice, index) = try Self.coordinate(name)
            bytes = try account.scriptPubKey(index: index, choice: choice)
        default: throw VectorError.malformed(name)
        }
        scriptCache[name] = bytes
        return bytes
    }

    func key(_ name: String) throws -> Data {
        switch name.first {
        case "i": return try leaves(name)[0].internalKey
        case "f":
            // An odd tag is also the wrong length.
            let tag = try Self.tag(name)
            return Self.digest("key \(tag)").prefix(tag % 2 == 0 ? 32 : 31)
        default: throw VectorError.malformed(name)
        }
    }

    func leaf(_ name: String) throws -> PSBT.TapLeafScript {
        switch name.first {
        case "s", "r":
            guard let leaf = try leaves(name).first(where: { $0.isRecovery == (name.first == "r") }) else {
                throw VectorError.malformed("\(name) on an account without that leaf")
            }
            return PSBT.TapLeafScript(controlBlock: leaf.controlBlock, script: leaf.script.bytes, leafVersion: leaf.version)
        case "f":
            let tag = try Self.tag(name)
            let block = Taproot.ControlBlock(leafVersion: Taproot.leafVersion, outputKeyParity: false,
                                             internalKey: Self.digest("leaf key \(tag)"),
                                             path: [Self.digest("leaf path \(tag)")])
            return PSBT.TapLeafScript(controlBlock: block, script: Data([0x51]) + Self.digest("leaf \(tag)"),
                                      leafVersion: Taproot.leafVersion)
        default: throw VectorError.malformed(name)
        }
    }

    func coin(_ coin: Vector.Coin) throws -> WalletUTXO {
        guard let chain = AddressChain(rawValue: coin.chain) else { throw VectorError.malformed("chain \(coin.chain)") }
        return WalletUTXO(txid: Self.txid(coin.txid), vout: coin.vout, amount: coin.amount,
                          scriptPubKey: try script(coin.script), chain: chain, index: coin.index,
                          height: coin.height, isCoinbase: coin.coinbase)
    }

    /// The PSBT a vector describes, field by field: a malformed field is
    /// present with a length its getter refuses.
    func psbt(_ shape: Vector.Shape) throws -> PSBT {
        let tx = Transaction(
            version: 2,
            inputs: shape.inputs.map { _ in
                Transaction.Input(previousOutput: .init(txid: Data(count: 32), vout: 0), scriptSig: Data(), sequence: 0)
            },
            outputs: shape.outputs.map { _ in Transaction.Output(value: 1, scriptPubKey: Data([0x51])) },
            locktime: 0)
        var psbt = try PSBT(unsignedTx: tx,
                            inputs: tx.inputs.map { _ in .init(spentOutput: .init(amount: 0, scriptPubKey: Data())) },
                            outputs: tx.outputs.map { _ in .init() })
        psbt.globals = psbt.globals.map {
            $0.type == PSBT.GlobalType.txVersion
                ? PSBT.KeyValue(type: PSBT.GlobalType.txVersion, value: PSBT.int32le(shape.version)) : $0
        }
        for (position, input) in shape.inputs.enumerated() {
            var target = psbt.inputs[position]
            switch input.txid {
            case let .value(tag): target.previousTxid = Self.txid(tag)
            case .absent: target.previousTxid = nil
            case .malformed: target.previousTxid = Data(repeating: 0xAB, count: 31)
            }
            Self.put(input.vout, type: PSBT.InType.outputIndex, into: &target)
            Self.put(input.sequence, type: PSBT.InType.sequence, into: &target)
            Self.put(input.sighash, type: PSBT.InType.sighashType, into: &target)
            switch input.witness {
            case let .value(witness):
                target.witnessUTXO = .init(amount: witness.amount, scriptPubKey: try script(witness.script))
            case .absent: target.witnessUTXO = nil
            case .malformed:
                // 1,000 sats and OP_TRUE, then a byte too many.
                let value = Data([0xE8, 0x03, 0, 0, 0, 0, 0, 0, 0x01, 0x51, 0x00])
                target.set(PSBT.KeyValue(type: PSBT.InType.witnessUTXO, value: value))
            }
            target.tapInternalKey = try input.internalKey.map(key)
            target.tapLeafScripts = try input.leaves.map(leaf)
            psbt.inputs[position] = target
        }
        for (position, output) in shape.outputs.enumerated() {
            switch output.amount {
            case let .value(amount): psbt.outputs[position].amount = amount
            case .absent: psbt.outputs[position].amount = nil
            case .malformed: psbt.outputs[position].set(PSBT.KeyValue(type: PSBT.OutType.amount, value: Data([1, 2, 3, 4])))
            }
            psbt.outputs[position].script = try output.script.map(script)
        }
        return psbt
    }

    /// A 4-byte field: absent, the value, or three bytes its getter refuses.
    private static func put(_ field: Field<UInt32>, type: UInt8, into input: inout PSBT.Input) {
        input.remove(type: type)
        switch field {
        case let .value(value): input.set(PSBT.KeyValue(type: type, value: PSBT.uint32le(value)))
        case .absent: break
        case .malformed: input.set(PSBT.KeyValue(type: type, value: Data([0x01, 0x02, 0x03])))
        }
    }

    /// Nil when `actual` is what the specification expects.
    func disagreement(_ actual: Outcome, expected: Vector.Expectation) throws -> String? {
        switch (actual, expected.accept, expected.reject) {
        case let (.accepted(review), accepted?, nil):
            var problems: [String] = []
            if review.outputs.count != accepted.outputs.count {
                problems.append("\(review.outputs.count) outputs shown, \(accepted.outputs.count) expected")
            }
            for (position, (shown, line)) in zip(review.outputs, accepted.outputs).enumerated() {
                let script = try script(line.script)
                if shown.amount != line.amount || shown.scriptPubKey != script || shown.isAccountOwned != line.owned {
                    problems.append("output \(position): shown \(shown.amount) owned \(shown.isAccountOwned), "
                        + "expected \(line.amount) \(line.script) owned \(line.owned)")
                }
            }
            if (review.inputTotal, review.outputTotal, review.fee) != (accepted.inputTotal, accepted.outputTotal, accepted.fee) {
                problems.append("totals \(review.inputTotal)/\(review.outputTotal)/\(review.fee), expected "
                    + "\(accepted.inputTotal)/\(accepted.outputTotal)/\(accepted.fee)")
            }
            if (review.path == .recovery ? "recovery" : "signers") != accepted.path {
                problems.append("path \(review.path), expected \(accepted.path)")
            }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        case let (.accepted(review), nil, rejected?):
            return "accepted (fee \(review.fee), path \(review.path)); expected refusal \(rejected.reason) at \(rejected.at.map(String.init) ?? "-")"
        case let (.refused(refusal), _?, nil):
            return "refused \(refusal); expected acceptance"
        case let (.refused(refusal), nil, rejected?):
            return refusal == Refusal(reason: rejected.reason, at: rejected.at) ? nil
                : "refused \(refusal); expected \(Refusal(reason: rejected.reason, at: rejected.at))"
        default:
            return "the vector has no single expectation"
        }
    }
}
