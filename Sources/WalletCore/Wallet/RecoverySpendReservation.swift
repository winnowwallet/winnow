import Foundation

/// Wallet inputs reserved for a child of a separately signed recovery
/// transaction. The external input is never signed by the Bitcoin wallet.
public struct RecoverySpendReservation: Codable, Equatable, Sendable {
    public let requestID: String
    public let rawTransaction: Data
    public let externalValue: Int64
    public let externalScript: Data
    public let selected: [WalletUTXO]
    public let changeIndex: UInt32
    public let fee: Int64
    public let feeLimit: Int64
    public var previousTxid: Data?
    public internal(set) var submitted = false

    public func transaction() throws -> Transaction { try Transaction.decode(rawTransaction) }

    func validate() throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 128, rawTransaction.count <= 400_000,
              externalValue >= 330, externalValue <= BitcoinAmount.maximum,
              externalScript.count == 34, externalScript.prefix(2) == Data([0, 32]),
              !selected.isEmpty, changeIndex < HDKey.hardenedOffset,
              fee > 0, fee <= feeLimit, feeLimit <= BitcoinAmount.maximum,
              previousTxid.map({ $0.count == 32 }) ?? true else {
            throw FundingReservationError.damagedRecord
        }
        let tx = try transaction()
        guard tx.inputs.count == selected.count + 1, (1...2).contains(tx.outputs.count),
              tx.inputs[0].scriptSig.isEmpty,
              Array(tx.inputs.dropFirst().map(\.previousOutput)) == selected.map(\.outpoint),
              Set(tx.inputs.map(\.previousOutput)).count == tx.inputs.count,
              tx.inputs.dropFirst().allSatisfy({
                  $0.scriptSig.isEmpty && $0.witness.count == 1 && $0.witness[0].count == 64
              })
        else {
            throw FundingReservationError.damagedRecord
        }
        try validateAmounts(tx)
    }

    private func validateAmounts(_ tx: Transaction) throws {
        var total = externalValue
        for coin in selected {
            guard coin.amount > 0, coin.amount <= BitcoinAmount.maximum - total,
                  coin.txid.count == 32, !coin.isSpent else {
                throw FundingReservationError.damagedRecord
            }
            total += coin.amount
        }
        let outputs = try tx.outputs.reduce(Int64(0)) { total, output in
            guard output.value > 0, output.value <= BitcoinAmount.maximum - total else {
                throw FundingReservationError.damagedRecord
            }
            return total + output.value
        }
        guard total - outputs == fee else {
            throw FundingReservationError.damagedRecord
        }
    }

    func validateOwnership(descriptor: Descriptor, network: BitcoinNetwork, nextChangeIndex: UInt32) throws {
        for coin in selected {
            guard coin.index < HDKey.hardenedOffset,
                  try descriptor.derived(index: coin.index, bitcoinNetwork: network)[coin.chain.rawValue]
                    .scriptPubKey == coin.scriptPubKey
            else {
                throw FundingReservationError.damagedRecord
            }
        }
        guard nextChangeIndex > changeIndex,
              try transaction().outputs.last?.scriptPubKey
                == descriptor.derived(index: changeIndex, bitcoinNetwork: network)[AddressChain.change.rawValue]
                .scriptPubKey
        else {
            throw FundingReservationError.damagedRecord
        }
    }

    func authorizes(_ final: Transaction) throws -> Bool {
        let partial = try transaction()
        return partial.serialized(includeWitness: false) == final.serialized(includeWitness: false)
            && Array(partial.inputs.dropFirst().map(\.witness)) == Array(final.inputs.dropFirst().map(\.witness))
            && !final.inputs[0].witness.isEmpty
    }
}

extension WalletState {
    func validateReservations() throws {
        guard fundingReservations.count + recoveryReservations.count <= 128 else {
            throw FundingReservationError.damagedRecord
        }
        var identifiers = Set<String>()
        var inputs = Set<Transaction.Outpoint>()
        for reservation in fundingReservations {
            try reservation.validate()
            try Self.registerReservation(reservation.requestID, coins: reservation.selected,
                                         identifiers: &identifiers, inputs: &inputs)
        }
        for reservation in recoveryReservations {
            try reservation.validate()
            try Self.registerReservation(reservation.requestID, coins: reservation.selected,
                                         identifiers: &identifiers, inputs: &inputs)
        }
    }

    private static func registerReservation(_ id: String, coins: [WalletUTXO],
                                            identifiers: inout Set<String>,
                                            inputs: inout Set<Transaction.Outpoint>) throws {
        guard identifiers.insert(id).inserted else { throw FundingReservationError.damagedRecord }
        for coin in coins {
            guard inputs.insert(coin.outpoint).inserted else { throw FundingReservationError.damagedRecord }
        }
    }
}
