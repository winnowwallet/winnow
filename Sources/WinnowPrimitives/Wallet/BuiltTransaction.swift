import Foundation

/// The result of `Wallet.send`: the signed raw transaction plus its PSBT.
public struct BuiltTransaction: Equatable, Sendable {
    public var psbt: PSBT
    /// Fully signed, ready for TxBroadcaster.
    public var transaction: Transaction
    public var fee: Int64
    public var changeAmount: Int64?

    public init(psbt: PSBT, transaction: Transaction, fee: Int64, changeAmount: Int64?) {
        self.psbt = psbt
        self.transaction = transaction
        self.fee = fee
        self.changeAmount = changeAmount
    }
}
