import Foundation

public enum WalletError: Error, Equatable, LocalizedError {
    /// Descriptor isn't the wallet's single-sig form: tr(KEY) with a ranged
    /// BIP389 `<0;1>/*` derivation and origin info (see `Wallet.descriptor`).
    case invalidDescriptor(String)
    /// Bundle descriptor does not match the one derived from its mnemonic.
    case descriptorMismatch
    case invalidBundle(String)
    case noPayments
    /// The built transaction lost its change output (should not happen).
    case changeOutputMissing
    /// The signed transaction is past Bitcoin Core's standard size limit, so
    /// default relay policy rejects it. Coin selection refuses this earlier, on its
    /// estimate; this measures the bytes that were actually signed.
    case transactionTooLarge(vsize: Int, limit: Int)
    /// A seed-bearing export was requested, but the secret is an xprv (or
    /// missing) rather than a BIP39 mnemonic. Refusing is safer than emitting
    /// a bundle that looks spendable and is not.
    case mnemonicUnavailable
    /// A pending send has already removed the parent inputs from the UTXO
    /// set. Exporting now would ship only the unconfirmed change — if the
    /// send never confirms, a forward-only restore cannot see the original
    /// coins (their confirmation height is behind `lastKnownHeight`).
    case exportWhilePending
    /// A matched transaction carried impossible output values or a total
    /// beyond Bitcoin's consensus monetary range. Nothing is applied.
    case invalidTransactionAmounts
    /// Legacy signing metadata must not be silently discarded by JSONDecoder:
    /// the resulting coin would look ordinary but could not be spent here.
    case unsupportedWalletData
    /// The persisted wallet file is larger than any state this wallet writes,
    /// so it is refused before it is read rather than after it is held.
    case storageTooLarge(maxBytes: Int)

    public var errorDescription: String? {
        switch self {
        // The payload is bound and discarded on purpose; see below.
        case .invalidDescriptor:
            // Deliberately not echoed. This is reached with a descriptor taken
            // straight from an imported bundle, and a descriptor may carry an
            // extended *private* key — repeating it here would put key material
            // on screen, into a screenshot, and into whatever the user pastes
            // into a bug report.
            "That wallet descriptor could not be parsed. It is not repeated here, "
                + "because a descriptor can carry key material."
        case .descriptorMismatch:
            "Bundle descriptor does not match the mnemonic."
        case let .invalidBundle(reason):
            "Invalid import bundle: \(reason)"
        case .noPayments:
            "Nothing to send."
        case .changeOutputMissing:
            "The built transaction lost its change output."
        case let .transactionTooLarge(vsize, limit):
            "The signed transaction is \(vsize) vbytes, above the \(limit)-vbyte relay maximum."
        case .mnemonicUnavailable:
            "This wallet has no recovery phrase to export — it was imported from an extended key, not a BIP39 mnemonic."
        case .exportWhilePending:
            "Wait for pending transactions to confirm before exporting. A mid-send backup would drop the coins being spent."
        case .invalidTransactionAmounts:
            "A matched Bitcoin transaction contains invalid amounts. Wallet state was not changed."
        case .unsupportedWalletData:
            """
            This wallet contains unsupported signing data and cannot be opened here. \
            Keep the original wallet file and use compatible wallet software to recover these coins.
            """
        case let .storageTooLarge(maxBytes):
            "The wallet file is larger than the \(maxBytes / 1_048_576) MB this wallet can hold and was not read."
        }
    }
}
