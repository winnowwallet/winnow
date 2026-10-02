import Foundation

/// SegWit-v0 signature digest over Winnow's transaction model. The caller supplies
/// the scriptCode after the last executed OP_CODESEPARATOR, as required by BIP143.
/// Lightning's supported scripts contain no OP_CODESEPARATOR.
public enum SighashBIP143 {
    public enum HashType: UInt32, Sendable, CaseIterable {
        case all = 1, none = 2, single = 3
        case allAnyoneCanPay = 0x81, noneAnyoneCanPay = 0x82, singleAnyoneCanPay = 0x83
    }
    public enum Error: Swift.Error, Equatable { case invalidInput, invalidAmount, invalidOutpoint }

    public static func sighash(tx: Transaction, inputIndex: Int, scriptCode: Data,
                               value: Int64, hashType: HashType = .all) throws -> Data {
        guard tx.inputs.indices.contains(inputIndex) else { throw Error.invalidInput }
        guard value >= 0, value <= 2_100_000_000_000_000,
              tx.outputs.allSatisfy({ $0.value >= 0 && $0.value <= 2_100_000_000_000_000 })
        else { throw Error.invalidAmount }
        guard tx.inputs.allSatisfy({ $0.previousOutput.txid.count == 32 }) else { throw Error.invalidOutpoint }
        let mode = hashType.rawValue & 0x1f
        let anyone = hashType.rawValue & 0x80 != 0
        let input = tx.inputs[inputIndex]
        var message = Data()
        message.appendInt32(tx.version)
        message.append(hashPrevouts(tx, anyoneCanPay: anyone))
        message.append(hashSequence(tx, anyoneCanPay: anyone, mode: mode))
        message.append(input.previousOutput.txid)
        message.appendUInt32(input.previousOutput.vout)
        message.appendVarData(scriptCode)
        message.appendInt64(value)
        message.appendUInt32(input.sequence)
        message.append(hashOutputs(tx, inputIndex: inputIndex, mode: mode))
        message.appendUInt32(tx.locktime)
        message.appendUInt32(hashType.rawValue)
        return SHA256d.hash(message)
    }

    private static let zero = Data(repeating: 0, count: 32)

    /// hashPrevouts: every input's outpoint, or zero with ANYONECANPAY.
    private static func hashPrevouts(_ tx: Transaction, anyoneCanPay: Bool) -> Data {
        if anyoneCanPay { return zero }
        var prevouts = Data()
        for input in tx.inputs {
            prevouts.append(input.previousOutput.txid)
            prevouts.appendUInt32(input.previousOutput.vout)
        }
        return SHA256d.hash(prevouts)
    }

    /// hashSequence: every input's nSequence, or zero with ANYONECANPAY,
    /// SINGLE or NONE.
    private static func hashSequence(_ tx: Transaction, anyoneCanPay: Bool, mode: UInt32) -> Data {
        if anyoneCanPay || mode == 2 || mode == 3 { return zero }
        var sequences = Data()
        for input in tx.inputs { sequences.appendUInt32(input.sequence) }
        return SHA256d.hash(sequences)
    }

    /// hashOutputs: every output with ALL, only the output at the input's
    /// index with SINGLE, and zero otherwise. Unlike legacy sighash, SINGLE
    /// without a matching output uses zero, not the historical uint256::ONE.
    private static func hashOutputs(_ tx: Transaction, inputIndex: Int, mode: UInt32) -> Data {
        var outputs = Data()
        if mode == 1 {
            for output in tx.outputs { append(output, to: &outputs) }
        } else if mode == 3, tx.outputs.indices.contains(inputIndex) {
            append(tx.outputs[inputIndex], to: &outputs)
        } else {
            return zero
        }
        return SHA256d.hash(outputs)
    }

    private static func append(_ output: Transaction.Output, to data: inout Data) {
        data.appendInt64(output.value)
        data.appendVarData(output.scriptPubKey)
    }
}
