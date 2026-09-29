import Foundation
import WalletCore

extension LightningEngine {
    /// Winnow's transaction sizing with a caller-resolved wallet feerate. Until
    /// shutdown arrives, budget for the largest negotiated witness program.
    /// The returned value must be reviewed before authorizing closeChannel.
    public func estimatedClosingFee(channelID: Data, peer: Data, destination: Data, feeRateSatPerVByte: Double) throws -> UInt64 {
        try operational(peer)
        let channel = state.channels[try channelIndex(channelID, peer: peer)]
        let anySegwit = peers[peer]?.supports(LightningFeatures.shutdownAnySegwit) == true
        guard ChannelTerms.validShutdown(destination, anySegwit: anySegwit),
              feeRateSatPerVByte.isFinite, feeRateSatPerVByte > 0, feeRateSatPerVByte <= 10_000 else { throw LightningError.invalidAmount }
        let remote = channel.remoteShutdown ?? channel.remote?.shutdownScript ?? Data()
        let remoteScript = remote.isEmpty ? Data([anySegwit ? 0x51 : 0, anySegwit ? 40 : 32]) + Data(repeating: 0, count: anySegwit ? 40 : 32) : remote
        let transaction = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 0, count: 32), vout: 0),
            scriptSig: Data(), sequence: .max,
            witness: [Data(), Data(repeating: 0, count: 73), Data(repeating: 0, count: 73), Data(repeating: 0, count: 71)])],
            outputs: [.init(value: 1, scriptPubKey: destination), .init(value: 1, scriptPubKey: remoteScript)], locktime: 0)
        let fee = UInt64((Double(TransactionBuilder.vsize(of: transaction)) * feeRateSatPerVByte).rounded(.up))
        guard fee < channel.capacity else { throw LightningError.invalidAmount }
        return fee
    }
}
