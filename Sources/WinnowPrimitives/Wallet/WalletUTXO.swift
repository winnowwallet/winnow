import Foundation

/// Which chain of the wallet's multipath descriptor an address lives on
/// (BIP44 external/internal).
public enum AddressChain: Int, Codable, Sendable {
    case receive = 0
    case change = 1
}

/// A wallet-controlled unspent output, with the derivation coordinates needed
/// to sign for it.
public struct WalletUTXO: Equatable, Sendable, Codable {
    public var txid: Data // 32 bytes, internal byte order
    public var vout: UInt32
    public var amount: Int64
    public var scriptPubKey: Data
    public var chain: AddressChain
    public var index: UInt32
    /// Block height that confirmed it.
    public var height: UInt32
    /// Set when this output was created by a coinbase. Consensus forbids
    /// spending it until `Wallet.coinbaseMaturity` confirmations; the flag is
    /// absent from older state files and treated as false.
    public var isCoinbase: Bool
    /// Set when this coin has been spent. The row is kept rather than deleted
    /// so a reorg can put it back (#127).
    ///
    /// Rescanning forward from the fork cannot recreate a coin whose *creating*
    /// transaction is below the fork, and `HistoryEntry` cannot help: it stores
    /// aggregates -- txid, height, received, spent, fee -- with no outpoints,
    /// scripts, or derivation indices. From "this transaction spent 50,000 sats
    /// of ours" there is no way back to *which coins*. So the one fact that was
    /// being thrown away is retained, and everything else is still re-derived.
    public var spent: SpentMarker?

    /// What spent a coin, and when.
    public struct SpentMarker: Equatable, Sendable, Codable {
        /// The transaction that spent it.
        public var spentBy: Data
        /// The height that confirmed the spend, or nil while the spend exists
        /// only in our own pending send.
        ///
        /// The distinction is what stops a rollback from double-spending the
        /// wallet against itself: a coin whose spender is still in flight must
        /// stay reserved even when the rollback puts confirmed coins back,
        /// because the broadcaster will keep re-relaying that transaction.
        public var height: UInt32?

        public init(spentBy: Data, height: UInt32?) {
            self.spentBy = spentBy
            self.height = height
        }
    }

    /// True once the coin has been spent, confirmed or pending.
    public var isSpent: Bool { spent != nil }

    public init(txid: Data, vout: UInt32, amount: Int64, scriptPubKey: Data,
                chain: AddressChain, index: UInt32, height: UInt32,
                isCoinbase: Bool = false,
                spent: SpentMarker? = nil) {
        self.spent = spent
        self.txid = txid
        self.vout = vout
        self.amount = amount
        self.scriptPubKey = scriptPubKey
        self.chain = chain
        self.index = index
        self.height = height
        self.isCoinbase = isCoinbase
    }

    public var outpoint: Transaction.Outpoint {
        Transaction.Outpoint(txid: txid, vout: vout)
    }

    public var spentOutput: SighashBIP341.SpentOutput {
        SighashBIP341.SpentOutput(amount: amount, scriptPubKey: scriptPubKey)
    }

    // JSON: txid display hex, scriptPubKey hex (human-inspectable state file).
    private enum CodingKeys: String, CodingKey {
        // `silentPaymentTweak` is kept although this build never writes one:
        // the decoder needs the key to notice a wallet it must refuse.
        case txid, vout, amount, scriptPubKey, chain, index, height, silentPaymentTweak, isCoinbase
        case spent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let txid = Data(hex: try container.decode(String.self, forKey: .txid)) else {
            throw DecodingError.dataCorruptedError(forKey: .txid, in: container,
                                                   debugDescription: "bad txid hex")
        }
        guard let scriptPubKey = Data(hex: try container.decode(String.self, forKey: .scriptPubKey)) else {
            throw DecodingError.dataCorruptedError(forKey: .scriptPubKey, in: container,
                                                   debugDescription: "bad scriptPubKey hex")
        }
        // Reject legacy signing metadata even when null or malformed. Dropping
        // this key would silently turn an unsupported coin into an ordinary one.
        if container.contains(.silentPaymentTweak) {
            throw WalletError.unsupportedWalletData
        }
        self.init(txid: Data(txid.reversed()),
                  vout: try container.decode(UInt32.self, forKey: .vout),
                  amount: try container.decode(Int64.self, forKey: .amount),
                  scriptPubKey: scriptPubKey,
                  chain: try container.decode(AddressChain.self, forKey: .chain),
                  index: try container.decode(UInt32.self, forKey: .index),
                  height: try container.decode(UInt32.self, forKey: .height),
                  isCoinbase: try container.decodeIfPresent(Bool.self, forKey: .isCoinbase) ?? false,
                  // Absent in every state file written before #127, which is
                  // exactly right: those wallets deleted spent rows, so any row
                  // still present is unspent.
                  spent: try container.decodeIfPresent(SpentMarker.self, forKey: .spent))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(txid.displayHex, forKey: .txid)
        try container.encode(vout, forKey: .vout)
        try container.encode(amount, forKey: .amount)
        try container.encode(scriptPubKey.hex, forKey: .scriptPubKey)
        try container.encode(chain, forKey: .chain)
        try container.encode(index, forKey: .index)
        try container.encode(height, forKey: .height)
        // Absent for live coins, so an unspent row is byte-identical to before.
        try container.encodeIfPresent(spent, forKey: .spent)
        if isCoinbase { try container.encode(true, forKey: .isCoinbase) }
    }
}
