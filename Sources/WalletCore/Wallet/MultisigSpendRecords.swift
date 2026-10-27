import Foundation

/// The one spend a phone is collecting signatures for on a multisig
/// account: the PSBT as the screens pass it around, and who is being paid,
/// so a person's address index advances only when the spend is broadcast.
/// Kept on the account record, so it survives leaving the screen and
/// travels in every backup; `MultisigStore` drops it once any input is no
/// longer a live coin of the account. Script-path signatures never change
/// the txid, so the draft's is known from the start. Exercised by
/// AppTests/MultisigStoreTests and AppTests/MultisigAccountFlowTests.
public struct MultisigSpendDraft: Codable, Equatable, Sendable {
    /// A PSBT carrying every leaf and origin of a 32-leaf account is far
    /// under this.
    public static let maximumBytes = 1_024 * 1_024

    /// BIP174, base64.
    public var psbtBase64: String
    public var personID: String?
    public var paymentIndex: UInt32?
    public var createdAtHeight: UInt32

    public init(psbtBase64: String, personID: String? = nil, paymentIndex: UInt32? = nil, createdAtHeight: UInt32) {
        self.psbtBase64 = psbtBase64
        self.personID = personID
        self.paymentIndex = paymentIndex
        self.createdAtHeight = createdAtHeight
    }

    public func psbt() throws -> PSBT {
        guard psbtBase64.utf8.count <= Self.maximumBytes else {
            throw WalletError.invalidBundle("a multisig draft is too large")
        }
        return try PSBT(base64: psbtBase64)
    }

    public func txid() throws -> Data {
        try psbt().unsignedTransaction().txid
    }

    /// The coins it spends.
    public func inputs() throws -> [Transaction.Outpoint] {
        try psbt().unsignedTransaction().inputs.map(\.previousOutput)
    }
}

/// A spend this phone broadcast that no block has confirmed yet, with the
/// bytes, witness included, a restored phone needs to announce it again.
/// Removed when the spend confirms, loses to a conflicting spend, or is
/// given up. Exercised by AppTests/MultisigStoreTests and
/// AppTests/MultisigAccountFlowTests.
public struct InFlightSpend: Codable, Equatable, Sendable {
    /// A standard transaction weighs at most 400,000 units, and bytes never
    /// exceed weight.
    public static let maximumBytes = 400_000

    /// Internal byte order; display hex in JSON, as a history entry's.
    public var txid: Data
    public var rawTransaction: Data
    public var broadcastHeight: UInt32

    public init(txid: Data, rawTransaction: Data, broadcastHeight: UInt32) {
        self.txid = txid
        self.rawTransaction = rawTransaction
        self.broadcastHeight = broadcastHeight
    }

    public init(transaction: Transaction, broadcastHeight: UInt32) {
        self.init(txid: transaction.txid, rawTransaction: transaction.serialized(includeWitness: true),
                  broadcastHeight: broadcastHeight)
    }

    /// The bytes decoded, and refused unless they are the transaction named.
    public func transaction() throws -> Transaction {
        guard rawTransaction.count <= Self.maximumBytes else {
            throw WalletError.invalidBundle("an in-flight multisig spend is too large")
        }
        let transaction = try Transaction.decode(rawTransaction)
        guard transaction.txid == txid else {
            throw WalletError.invalidBundle("an in-flight multisig spend does not match its transaction ID")
        }
        return transaction
    }

    private enum CodingKeys: String, CodingKey { case txid, rawTransaction, broadcastHeight }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let txid = Data(hex: try container.decode(String.self, forKey: .txid)), txid.count == 32 else {
            throw DecodingError.dataCorruptedError(forKey: .txid, in: container, debugDescription: "bad txid hex")
        }
        self.init(txid: Data(txid.reversed()),
                  rawTransaction: try container.decode(Data.self, forKey: .rawTransaction),
                  broadcastHeight: try container.decode(UInt32.self, forKey: .broadcastHeight))
        _ = try transaction()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(txid.displayHex, forKey: .txid)
        try container.encode(rawTransaction, forKey: .rawTransaction)
        try container.encode(broadcastHeight, forKey: .broadcastHeight)
    }
}
