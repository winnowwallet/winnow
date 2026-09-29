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
        let zero = Data(repeating: 0, count: 32)
        var prevouts = Data(), sequences = Data(), outputs = Data()
        for input in tx.inputs {
            prevouts.append(input.previousOutput.txid)
            prevouts.appendUInt32(input.previousOutput.vout)
            sequences.appendUInt32(input.sequence)
        }
        if mode == 1 {
            for output in tx.outputs { append(output, to: &outputs) }
        } else if mode == 3, tx.outputs.indices.contains(inputIndex) {
            append(tx.outputs[inputIndex], to: &outputs)
        }
        let input = tx.inputs[inputIndex]
        var message = Data()
        message.appendInt32(tx.version)
        message.append(anyone ? zero : SHA256d.hash(prevouts))
        message.append(anyone || mode == 2 || mode == 3 ? zero : SHA256d.hash(sequences))
        message.append(input.previousOutput.txid)
        message.appendUInt32(input.previousOutput.vout)
        message.appendVarData(scriptCode)
        message.appendInt64(value)
        message.appendUInt32(input.sequence)
        // Unlike legacy sighash, SINGLE without a matching output uses zero
        // hashOutputs, not the historical uint256::ONE result.
        message.append(mode == 1 || (mode == 3 && tx.outputs.indices.contains(inputIndex))
                       ? SHA256d.hash(outputs) : zero)
        message.appendUInt32(tx.locktime)
        message.appendUInt32(hashType.rawValue)
        return SHA256d.hash(message)
    }

    private static func append(_ output: Transaction.Output, to data: inout Data) {
        data.appendInt64(output.value)
        data.appendVarData(output.scriptPubKey)
    }
}
