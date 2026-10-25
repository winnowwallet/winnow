import Foundation

/// Why a receiver's Proposal PSBT was refused. Each case is one line of the
/// BIP 78 sender checklist, or one of the wallet's own tighter rules.
public enum PayjoinProposalError: Error, Equatable {
    case versionChanged
    case locktimeChanged
    case senderInputsMissingOrShuffled
    case duplicateInput
    case inputCarriesKeyPaths(Int)
    case inputCarriesPartialSignatures(Int)
    case senderInputSequenceChanged(Int)
    case senderInputAlreadyFinalized(Int)
    case senderInputSighashType(Int)
    case receiverInputNotFinalized(Int)
    case receiverInputMissingUTXO(Int)
    case receiverInputSequenceDiffers(Int)
    case outputCarriesKeyPaths(Int)
    case paymentOutputChanged
    case senderOutputsMissingOrShuffled
    case senderOutputReduced(Int)
    case feeContributionExceedsMaximum(contributed: Int64, maximum: Int64)
    case absoluteFeeDecreased(original: Int64, proposed: Int64)
    case contributionNotSpentOnFee
    case contributionExceedsAddedInputs(contributed: Int64, allowed: Int64)
    case feeRateBelowMinimum(satPerVByte: Double, minimum: Double)
    case senderSpendExceedsAuthorized(spend: Int64, authorized: Int64)
    case malformed(String)
}

/// What the sender agreed to when it built the Original PSBT, and the
/// checks that hold a Proposal PSBT to it (BIP 78 "Sender's payjoin
/// proposal checklist", as BIP 77 inherits it). Output substitution is
/// always disabled: the payment output must keep its script, because the
/// review bound that script. The receiver may add inputs and outputs, raise
/// the payment, and take up to `maxFeeContribution` from the change output
/// at `feeOutputIndex`, but only to pay for the inputs it added.
///
/// Exercised by `PayjoinProposalTests` with BIP 78's vectors and a set of
/// hostile proposals.
public struct PayjoinContext: Equatable, Sendable {
    /// The finalized Original PSBT, with the sender's witness UTXOs.
    public var original: PSBT
    public var payeeScript: Data
    public var payeeAmount: Int64
    /// The change output the receiver may draw fees from, and the cap.
    public var feeOutputIndex: Int?
    public var maxFeeContribution: Int64
    /// `minfeerate`: the proposal, once signed, must pay at least this.
    public var minFeeRateSatPerVByte: Double

    public init(original: PSBT, payeeScript: Data, payeeAmount: Int64, feeOutputIndex: Int?,
                maxFeeContribution: Int64, minFeeRateSatPerVByte: Double) throws {
        self.original = original
        self.payeeScript = payeeScript
        self.payeeAmount = payeeAmount
        self.feeOutputIndex = maxFeeContribution > 0 ? feeOutputIndex : nil
        self.maxFeeContribution = feeOutputIndex == nil ? 0 : max(0, maxFeeContribution)
        self.minFeeRateSatPerVByte = minFeeRateSatPerVByte
        try validateOriginal()
    }

    private func validateOriginal() throws {
        let tx = try original.extractedTransaction()
        let payees = tx.outputs.filter { $0.scriptPubKey == payeeScript }
        guard payees.count == 1, payees[0].value == payeeAmount else {
            throw PayjoinProposalError.malformed("original must pay the payee exactly once")
        }
        if let feeOutputIndex {
            guard tx.outputs.indices.contains(feeOutputIndex), tx.outputs[feeOutputIndex].scriptPubKey != payeeScript,
                  tx.outputs[feeOutputIndex].value >= maxFeeContribution
            else { throw PayjoinProposalError.malformed("fee output") }
        }
        for (index, input) in original.inputs.enumerated() {
            guard input.spentOutput() != nil else { throw PayjoinProposalError.malformed("original input \(index) utxo") }
            if let type = input.sighashType, type != 0, type != 1 {
                throw PayjoinProposalError.senderInputSighashType(index)
            }
        }
    }

    // MARK: - Original PSBT body

    /// The optional sender parameters BIP 78 defines, as a query string.
    /// `v=2` is what the reference receiver expects even though BIP 77 calls
    /// it redundant; output substitution is always disabled here.
    public var senderParameters: String {
        var parts = ["v=2", "disableoutputsubstitution=true"]
        if let feeOutputIndex, maxFeeContribution > 0 {
            parts.append("additionalfeeoutputindex=\(feeOutputIndex)")
            parts.append("maxadditionalfeecontribution=\(maxFeeContribution)")
        }
        if minFeeRateSatPerVByte > 0 {
            parts.append("minfeerate=\(Self.decimal(minFeeRateSatPerVByte))")
        }
        return parts.joined(separator: "&")
    }

    static func decimal(_ rate: Double) -> String {
        let hundredths = (rate * 100).rounded(.down)
        let text = String(format: "%.2f", hundredths / 100)
        return text.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }

    /// The Message A body: the stripped Original PSBT in BIP 174 base64,
    /// then the parameters on a new line.
    public func messageBody() throws -> Data {
        Data((try original.strippedForPayjoin().base64V0() + "\n" + senderParameters).utf8)
    }

    // MARK: - Fee facts about the original

    public func originalTransaction() throws -> Transaction { try original.extractedTransaction() }

    public func originalFee() throws -> Int64 {
        try original.inputs.reduce(Int64(0)) { sum, input in
            guard let spent = input.spentOutput() else { throw PayjoinProposalError.malformed("original utxo") }
            return sum + spent.amount
        } - (try originalTransaction()).outputs.reduce(0) { $0 + $1.value }
    }

    /// Fee rate of the original in sat/vB.
    public func originalFeeRate() throws -> Double {
        Double(try originalFee()) / Double(TransactionBuilder.vsize(of: try originalTransaction()))
    }

    // MARK: - The checklist

    /// Checks `proposal` against the original and returns it ready for the
    /// sender to sign: the sender's inputs carry their witness UTXOs and
    /// sighash types again, exactly as in the original.
    public func check(proposal incoming: PSBT) throws -> CheckedProposal {
        var proposal = incoming
        try checkHeader(proposal)
        let inputs = try checkInputs(&proposal)
        let outputs = try checkOutputs(proposal)
        let fees = try checkFees(proposal, senderIndices: inputs.senderIndices, contributed: outputs.contributed,
                                 addedWeight: inputs.addedWeight)
        let senderInputTotal = try inputs.senderIndices.reduce(Int64(0)) { sum, index in
            guard let spent = proposal.inputs[index].spentOutput() else { throw PayjoinProposalError.malformed("utxo") }
            return sum + spent.amount
        }
        let spend = senderInputTotal - outputs.senderOutputTotal
        let authorized = payeeAmount + (try originalFee()) + maxFeeContribution
        guard spend <= authorized else {
            throw PayjoinProposalError.senderSpendExceedsAuthorized(spend: spend, authorized: authorized)
        }
        return CheckedProposal(psbt: proposal, senderInputIndices: inputs.senderIndices,
                               receiverInputCount: proposal.inputs.count - inputs.senderIndices.count,
                               contributedFee: outputs.contributed, proposedFee: fees.proposedFee,
                               originalFee: fees.originalFee, minFeeRateSatPerVByte: minFeeRateSatPerVByte,
                               senderSpend: spend)
    }

    private func checkHeader(_ proposal: PSBT) throws {
        guard proposal.txVersion == original.txVersion else { throw PayjoinProposalError.versionChanged }
        guard proposal.fallbackLocktime == original.fallbackLocktime else { throw PayjoinProposalError.locktimeChanged }
    }

    private struct InputFacts {
        var senderIndices: [Int]
        var addedWeight: Int
    }

    /// BIP 78: the receiver may insert inputs, never drop or reorder ours.
    private func requireOriginalInputsInOrder(_ proposal: PSBT) throws {
        var remaining = original.inputs[...]
        for input in proposal.inputs where remaining.first.map({ Self.sameOutpoint($0, input) }) == true {
            remaining = remaining.dropFirst()
        }
        guard remaining.isEmpty else { throw PayjoinProposalError.senderInputsMissingOrShuffled }
    }

    private static func sameOutpoint(_ lhs: PSBT.Input, _ rhs: PSBT.Input) -> Bool {
        lhs.previousTxid == rhs.previousTxid && lhs.outputIndex == rhs.outputIndex
    }

    /// The sender's inputs appear in order as a subsequence, untouched and
    /// unsigned; every other input is the receiver's, finalized, with its
    /// UTXO, sharing the sender's sequence number.
    private func checkInputs(_ proposal: inout PSBT) throws -> InputFacts {
        try requireOriginalInputsInOrder(proposal)
        var originalIndex = 0
        var facts = InputFacts(senderIndices: [], addedWeight: 0)
        var seen: Set<Transaction.Outpoint> = []
        let sequence = original.inputs.first?.sequence ?? 0xFFFF_FFFF
        for index in proposal.inputs.indices {
            let input = proposal.inputs[index]
            try checkAnyInput(input, at: index, seen: &seen)
            if originalIndex < original.inputs.count, Self.sameOutpoint(original.inputs[originalIndex], input) {
                try checkSenderInput(input, at: index, original: original.inputs[originalIndex])
                proposal.inputs[index].witnessUTXO = original.inputs[originalIndex].witnessUTXO
                proposal.inputs[index].sighashType = 0
                facts.senderIndices.append(index)
                originalIndex += 1
            } else {
                try checkReceiverInput(input, at: index, sequence: sequence)
                facts.addedWeight += Self.weight(ofFinalizedInput: input)
            }
        }
        return facts
    }

    /// Rules for every input, ours or theirs: a unique outpoint, no key
    /// paths, no partial signatures.
    private func checkAnyInput(_ input: PSBT.Input, at index: Int, seen: inout Set<Transaction.Outpoint>) throws {
        guard let txid = input.previousTxid, let vout = input.outputIndex else {
            throw PayjoinProposalError.malformed("input \(index) outpoint")
        }
        guard seen.insert(Transaction.Outpoint(txid: txid, vout: vout)).inserted else {
            throw PayjoinProposalError.duplicateInput
        }
        guard !input.carriesKeyPaths else { throw PayjoinProposalError.inputCarriesKeyPaths(index) }
        guard !input.carriesPartialSignatures else { throw PayjoinProposalError.inputCarriesPartialSignatures(index) }
    }

    private func checkSenderInput(_ input: PSBT.Input, at index: Int, original: PSBT.Input) throws {
        guard input.sequence == original.sequence else { throw PayjoinProposalError.senderInputSequenceChanged(index) }
        guard !input.isFinalized else { throw PayjoinProposalError.senderInputAlreadyFinalized(index) }
        if let type = input.sighashType, type != 0, type != 1 { throw PayjoinProposalError.senderInputSighashType(index) }
    }

    private func checkReceiverInput(_ input: PSBT.Input, at index: Int, sequence: UInt32) throws {
        guard input.isFinalized else { throw PayjoinProposalError.receiverInputNotFinalized(index) }
        guard input.spentOutput() != nil else { throw PayjoinProposalError.receiverInputMissingUTXO(index) }
        guard input.sequence == sequence else { throw PayjoinProposalError.receiverInputSequenceDiffers(index) }
    }

    /// The weight a finalized input adds to the transaction: its base bytes
    /// four times, plus its witness bytes once.
    static func weight(ofFinalizedInput input: PSBT.Input) -> Int {
        let scriptSig = input.finalScriptSig ?? Data()
        var base = Data()
        base.appendVarData(scriptSig)
        let baseBytes = 32 + 4 + base.count + 4
        var witness = Data()
        if let items = input.finalScriptWitness {
            witness.appendCompactSize(UInt64(items.count))
            for item in items { witness.appendVarData(item) }
        }
        return baseBytes * 4 + witness.count
    }

    private struct OutputFacts {
        var contributed: Int64
        var senderOutputTotal: Int64
    }

    /// The original's outputs appear in order as a subsequence: the payment
    /// output with its script unchanged and its value not reduced, the fee
    /// output reduced by at most the contribution, every other sender
    /// output not reduced.
    private func checkOutputs(_ proposal: PSBT) throws -> OutputFacts {
        let originalOutputs = try originalTransaction().outputs
        var originalIndex = 0
        var facts = OutputFacts(contributed: 0, senderOutputTotal: 0)
        for (index, output) in proposal.outputs.enumerated() {
            guard !output.carriesKeyPaths else { throw PayjoinProposalError.outputCarriesKeyPaths(index) }
            guard let script = output.script, let value = output.amount else {
                throw PayjoinProposalError.malformed("output \(index)")
            }
            // Past the last original, or a script that is not the next
            // original's: the receiver's own output.
            guard originalIndex < originalOutputs.count, script == originalOutputs[originalIndex].scriptPubKey else {
                continue
            }
            try checkMatchedOutput(value: value, at: index, original: originalOutputs[originalIndex],
                                   originalIndex: originalIndex, facts: &facts)
            originalIndex += 1
        }
        guard originalIndex == originalOutputs.count else { throw PayjoinProposalError.senderOutputsMissingOrShuffled }
        return facts
    }

    private func checkMatchedOutput(value: Int64, at index: Int, original: Transaction.Output, originalIndex: Int,
                                    facts: inout OutputFacts) throws {
        if original.scriptPubKey == payeeScript {
            guard value >= original.value else { throw PayjoinProposalError.paymentOutputChanged }
            return
        }
        facts.senderOutputTotal += value
        if originalIndex == feeOutputIndex, value < original.value {
            facts.contributed = original.value - value
            guard facts.contributed <= maxFeeContribution else {
                throw PayjoinProposalError.feeContributionExceedsMaximum(contributed: facts.contributed,
                                                                         maximum: maxFeeContribution)
            }
            return
        }
        guard value >= original.value else { throw PayjoinProposalError.senderOutputReduced(index) }
    }

    private struct FeeFacts {
        var originalFee: Int64
        var proposedFee: Int64
    }

    private func checkFees(_ proposal: PSBT, senderIndices: [Int], contributed: Int64,
                           addedWeight: Int) throws -> FeeFacts {
        let inputTotal = try proposal.inputs.enumerated().reduce(Int64(0)) { sum, element in
            guard let spent = element.element.spentOutput() else {
                throw PayjoinProposalError.receiverInputMissingUTXO(element.offset)
            }
            return sum + spent.amount
        }
        let outputTotal = proposal.outputs.reduce(Int64(0)) { $0 + ($1.amount ?? 0) }
        let proposedFee = inputTotal - outputTotal
        let originalFee = try originalFee()
        guard proposedFee >= originalFee else {
            throw PayjoinProposalError.absoluteFeeDecreased(original: originalFee, proposed: proposedFee)
        }
        guard contributed <= proposedFee - originalFee else { throw PayjoinProposalError.contributionNotSpentOnFee }
        // The contribution pays only for what the receiver's inputs weigh.
        let allowed = Int64((try originalFeeRate() * Double(addedWeight) / 4).rounded(.up))
        guard contributed <= allowed else {
            throw PayjoinProposalError.contributionExceedsAddedInputs(contributed: contributed, allowed: allowed)
        }
        return FeeFacts(originalFee: originalFee, proposedFee: proposedFee)
    }
}

/// A proposal that passed every check, with what the sender learned.
public struct CheckedProposal: Equatable, Sendable {
    /// Ready to sign: the sender's inputs carry their UTXOs again.
    public var psbt: PSBT
    public var senderInputIndices: [Int]
    public var receiverInputCount: Int
    /// What the receiver took from the change output.
    public var contributedFee: Int64
    public var proposedFee: Int64
    public var originalFee: Int64
    public var minFeeRateSatPerVByte: Double
    /// Σ sender inputs − Σ sender outputs: what leaves the wallet.
    public var senderSpend: Int64

    public init(psbt: PSBT, senderInputIndices: [Int], receiverInputCount: Int, contributedFee: Int64,
                proposedFee: Int64, originalFee: Int64, minFeeRateSatPerVByte: Double, senderSpend: Int64) {
        self.psbt = psbt
        self.senderInputIndices = senderInputIndices
        self.receiverInputCount = receiverInputCount
        self.contributedFee = contributedFee
        self.proposedFee = proposedFee
        self.originalFee = originalFee
        self.minFeeRateSatPerVByte = minFeeRateSatPerVByte
        self.senderSpend = senderSpend
    }

    /// The fee rate check that needs the signed transaction (BIP 78: "once
    /// the proposal is signed").
    public func verifyFeeRate(of signed: Transaction) throws {
        let rate = Double(proposedFee) / Double(TransactionBuilder.vsize(of: signed))
        guard rate + 0.000_001 >= minFeeRateSatPerVByte else {
            throw PayjoinProposalError.feeRateBelowMinimum(satPerVByte: rate, minimum: minFeeRateSatPerVByte)
        }
    }
}
