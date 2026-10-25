import Foundation
import P256K
import WalletCore

/// The other side of a BIP 77 payjoin, for tests: a receiver with a session
/// key, a mailbox on a `FakePayjoinDirectory`, a P2TR coin of its own, and
/// a proposal builder with a dial of hostile behaviours. It talks to the
/// directory's mailboxes in process; only the wallet goes through HTTP and
/// OHTTP. Written against the BIPs and WalletCore's public types, never the
/// sender code under test.
public final class FakePayjoinReceiver: @unchecked Sendable {
    public typealias Curve = HPKE.Secp256k1

    /// What the receiver does with the Original PSBT.
    public enum Behaviour: Sendable, Equatable {
        /// Adds its coin, pays itself the added value on top of the payment,
        /// takes the allowed contribution from the sender's change.
        case honest
        /// Adds nothing and echoes the original unsigned: valid, no payjoin.
        case echo
        /// Takes more from the sender's change than the contribution allows.
        case stealChange
        /// Lowers the payment output.
        case reducePayment
        /// Redirects the payment output to its own script.
        case redirectPayment
        /// Replaces the sender's first input with another outpoint.
        case swapSenderInput
        /// Leaves the sender's first input out.
        case dropSenderInput
        /// Lists the sender's first input twice.
        case duplicateSenderInput
        /// Pays itself so much the absolute fee falls below the original.
        case decreaseFee
        /// Takes the whole allowed contribution for an input lighter than it.
        case overchargeForInput
        /// Adds its input but no fee at all: every check passes except the
        /// fee-rate floor, which only the signed transaction can show.
        case underpayFeeRate
        /// Leaves its own input unsigned.
        case unfinalizedInput
        /// Leaves a BIP 32 key path on the sender's input.
        case leaveKeyPaths
        /// Changes the sender's input sequence.
        case changeSequence
        /// Changes the locktime.
        case changeLocktime
        /// Answers with a BIP 78 JSON error.
        case error(String)
        /// Never answers.
        case silent
    }

    public struct Coin: Sendable {
        public var outpoint: Transaction.Outpoint
        public var amount: Int64
        public var scriptPubKey: Data
        public var tweakedPrivateKey: Data

        public init(outpoint: Transaction.Outpoint, amount: Int64, scriptPubKey: Data, tweakedPrivateKey: Data) {
            self.outpoint = outpoint
            self.amount = amount
            self.scriptPubKey = scriptPubKey
            self.tweakedPrivateKey = tweakedPrivateKey
        }
    }

    public let network: BitcoinNetwork
    public let directory: FakePayjoinDirectory
    let sessionKey: Curve.PrivateKey
    /// The receiver's payment address and the key behind it.
    public let address: String
    public let paymentScript: Data
    private let paymentSecret: Data
    public private(set) var coin: Coin?
    public let expiry: Date
    /// What the receiver saw: the Original PSBT and the sender parameters.
    public private(set) var receivedOriginal: PSBT?
    public private(set) var receivedParameters: [String: String] = [:]
    public private(set) var lastProposal: PSBT?

    public init(network: BitcoinNetwork, directory: FakePayjoinDirectory,
                expiry: Date = Date().addingTimeInterval(3_600)) throws {
        self.network = network
        self.directory = directory
        self.expiry = expiry
        sessionKey = try Curve.generatePrivateKey()
        let secret = try P256K.Schnorr.PrivateKey().dataRepresentation
        let internalKey = try P256K.Schnorr.PrivateKey(dataRepresentation: secret).xonly.bytes
        paymentSecret = try BIP86.tweakedPrivateKey(secret)
        paymentScript = try BIP86.scriptPubKey(internalKey: Data(internalKey))
        address = try BIP86.address(internalKey: Data(internalKey), hrp: network == .mainnet ? "bc" : "tb")
    }

    public var receiverKey: Data { Curve.compressed(sessionKey.publicKey) }
    public var mailboxID: String { PayjoinShortID.derive(compressedKey: receiverKey) }

    /// Gives the receiver a coin to contribute: a fake outpoint for unit
    /// tests, or a real one the journey funded through Core. Its key is the
    /// payment address's key, so `scriptPubKey` must be `paymentScript`
    /// unless `tweakedPrivateKey` is supplied.
    public func fund(outpoint: Transaction.Outpoint, amount: Int64, scriptPubKey: Data? = nil,
                     tweakedPrivateKey: Data? = nil) {
        coin = Coin(outpoint: outpoint, amount: amount, scriptPubKey: scriptPubKey ?? paymentScript,
                    tweakedPrivateKey: tweakedPrivateKey ?? paymentSecret)
    }

    /// The session parameters, as the wallet will parse them.
    public func parameters() async -> PayjoinParameters {
        PayjoinParameters(directory: await directory.url, mailboxID: mailboxID, receiverKey: receiverKey,
                          ohttpKeyConfig: await directory.keyConfig, expiry: expiry)
    }

    /// The BIP 21 URI to hand the wallet.
    public func uri(amountSats: Int64? = nil, required: Bool = false) async -> String {
        var query: [String] = []
        if let amountSats {
            let btc = String(format: "%d.%08d", amountSats / 100_000_000, amountSats % 100_000_000)
            query.append("amount=\(btc)")
        }
        query.append("pjos=0")
        query.append("\(required ? "req-pj" : "pj")=\(await parameters().queryValue)")
        return "bitcoin:\(address)?\(query.joined(separator: "&"))"
    }

    // MARK: - Receiving

    /// Waits for an Original PSBT in the receiver mailbox and decrypts it.
    public func awaitOriginal(timeout: Duration = .seconds(30)) async throws -> (psbt: PSBT, replyKey: Curve.PublicKey) {
        guard let message = await directory.await(mailbox: mailboxID, timeout: timeout) else {
            throw ReceiverError.timeout
        }
        let (padded, replyKey) = try PayjoinMessage.decryptA(message, receiverKey: sessionKey)
        let text = String(decoding: PayjoinMessage.unpadded(padded), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let base64 = lines.first else { throw ReceiverError.malformedBody }
        let psbt = try PSBT(base64: String(base64))
        receivedOriginal = psbt
        receivedParameters = [:]
        if lines.count > 1 {
            for pair in lines[1].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                receivedParameters[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        return (psbt, replyKey)
    }

    /// Answers the sender's mailbox with Message B carrying `body`.
    public func reply(_ body: Data, to replyKey: Curve.PublicKey) async throws {
        let message = try PayjoinMessage.encryptB(body: body, receiverKey: sessionKey, replyKey: replyKey)
        let mailbox = PayjoinShortID.derive(compressedKey: Curve.compressed(replyKey))
        await directory.post(mailbox: mailbox, message)
    }

    /// One full receiver turn: wait for the original, answer per `behaviour`.
    public func serve(_ behaviour: Behaviour, timeout: Duration = .seconds(30)) async throws {
        let (original, replyKey) = try await awaitOriginal(timeout: timeout)
        switch behaviour {
        case .silent:
            return
        case let .error(code):
            try await reply(Data("{\"errorCode\":\"\(code)\",\"message\":\"receiver text\"}".utf8), to: replyKey)
        default:
            let proposal = try buildProposal(original: original, parameters: receivedParameters, behaviour: behaviour)
            lastProposal = proposal
            try await reply(Data(try proposal.base64V0().utf8), to: replyKey)
        }
    }

    public enum ReceiverError: Error {
        case timeout
        case malformedBody
        case noCoin
        case noChange
    }

    // MARK: - The proposal

    /// A Proposal PSBT from the Original: the receiver's coin added at index
    /// 1, the payment output raised by its value less the fee it pays for
    /// itself, the sender's change reduced by the allowed contribution, the
    /// receiver's input signed and finalized, the sender's inputs stripped
    /// of UTXO data and witnesses as BIP 78 asks. `behaviour` bends one rule.
    public func buildProposal(original: PSBT, parameters: [String: String], behaviour: Behaviour) throws -> PSBT {
        var tx = try original.extractedTransaction()
        let senderSpent = try original.spentOutputs()
        let senderFee = senderSpent.reduce(0) { $0 + $1.amount } - tx.outputs.reduce(0) { $0 + $1.value }
        let feeRate = Double(senderFee) / Double(TransactionBuilder.vsize(of: tx))
        for index in tx.inputs.indices {
            tx.inputs[index].witness = []
            tx.inputs[index].scriptSig = Data()
        }
        let contributionIndex = parameters["additionalfeeoutputindex"].flatMap(Int.init)
        let maxContribution = parameters["maxadditionalfeecontribution"].flatMap(Int64.init) ?? 0
        guard let payeeIndex = tx.outputs.firstIndex(where: { $0.scriptPubKey == paymentScript }) else {
            throw ReceiverError.malformedBody
        }
        var spent = senderSpent
        var receiverIndex: Int?
        let originalPayment = tx.outputs[payeeIndex].value
        if behaviour == .dropSenderInput {
            tx.inputs.remove(at: 0)
            spent.remove(at: 0)
        }
        if behaviour != .echo {
            guard let coin else { throw ReceiverError.noCoin }
            let input = Transaction.Input(previousOutput: coin.outpoint, scriptSig: Data(),
                                          sequence: tx.inputs.first?.sequence ?? 0xFFFF_FFFD)
            let at = min(1, tx.inputs.count)
            tx.inputs.insert(input, at: at)
            spent.insert(SighashBIP341.SpentOutput(amount: coin.amount, scriptPubKey: coin.scriptPubKey), at: at)
            receiverIndex = at
            // The fee its own P2TR key-path input costs (57.5 vbytes) is what
            // the sender may be asked for. What the receiver actually adds is
            // whatever keeps the whole transaction at the sender's minfeerate
            // (the reference receiver does the same), never less than that.
            let addedFee = Int64((feeRate * 57.5).rounded(.up))
            var contribution = min(maxContribution, addedFee)
            let minRate = parameters["minfeerate"].flatMap(Double.init) ?? feeRate
            let newVsize = Double(TransactionBuilder.vsize(of: try original.extractedTransaction())) + 58
            var feeIncrease = max(addedFee, Int64((minRate * newVsize).rounded(.up)) - senderFee)
            switch behaviour {
            case .stealChange: contribution = maxContribution + 1_000
            case .overchargeForInput:
                contribution = maxContribution
                feeIncrease = maxContribution
            case .underpayFeeRate:
                contribution = 0
                feeIncrease = 0
            default: break
            }
            if let contributionIndex, contribution > 0 {
                tx.outputs[contributionIndex].value -= contribution
            } else {
                contribution = 0
            }
            // The receiver keeps its coin's value and whatever contribution
            // it did not spend on fees: both go onto the payment output.
            tx.outputs[payeeIndex].value += coin.amount + contribution - feeIncrease
        }
        try applyHostility(behaviour, to: &tx, spent: &spent, payeeIndex: payeeIndex, originalPayment: originalPayment)
        var proposal = try PSBT(unsignedTx: tx, inputs: spent.map { PSBT.InputInfo(spentOutput: $0) },
                                outputs: tx.outputs.map { _ in PSBT.OutputInfo() })
        if let receiverIndex, let coin, behaviour != .unfinalizedInput {
            let witness = try Signer.witness(tx: tx, inputIndex: receiverIndex, spentOutputs: spent,
                                             tweakedPrivateKey: coin.tweakedPrivateKey)
            proposal.inputs[receiverIndex].finalScriptWitness = witness
            proposal.inputs[receiverIndex].pairs.removeAll { $0.type == PSBT.InType.sighashType }
        }
        for index in proposal.inputs.indices where index != receiverIndex {
            proposal.inputs[index].witnessUTXO = nil
            proposal.inputs[index].pairs.removeAll { $0.type == PSBT.InType.sighashType }
            if behaviour == .leaveKeyPaths {
                proposal.inputs[index].pairs.append(PSBT.KeyValue(type: 0x06, keyData: Data(repeating: 2, count: 33),
                                                                  value: Data(repeating: 0, count: 8)))
            }
        }
        return proposal
    }

    private func applyHostility(_ behaviour: Behaviour, to tx: inout Transaction,
                                spent: inout [SighashBIP341.SpentOutput], payeeIndex: Int,
                                originalPayment: Int64) throws {
        switch behaviour {
        case .reducePayment: tx.outputs[payeeIndex].value = originalPayment - 1
        case .redirectPayment: tx.outputs[payeeIndex].scriptPubKey = Data([0x51, 0x20] + repeatElement(0xEE, count: 32))
        case .swapSenderInput: tx.inputs[0].previousOutput.vout += 1
        case .duplicateSenderInput:
            tx.inputs.append(tx.inputs[0])
            spent.append(spent[0])
        case .decreaseFee: tx.outputs[payeeIndex].value += 5_000
        case .changeSequence: tx.inputs[0].sequence = 0xFFFF_FFFE
        case .changeLocktime: tx.locktime += 1
        default: break
        }
    }
}
