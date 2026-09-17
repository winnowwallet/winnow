import Foundation
import WalletCore

/// Prepares the disposable node before UI testing and recording begin.
public enum SignetFixture {
    public static let bank = "ui-bank"
    private static let minimumBalance: Int64 = 1_000_000_000

    public enum FixtureError: LocalizedError {
        case wrongChain
        case bankNotPrepared
        case filtersNotReady

        public var errorDescription: String? {
            switch self {
            case .wrongChain: "Use the disposable signet fixture."
            case .bankNotPrepared: "Prepare the bank first with swift run winnow-fixture prepare-bank."
            case .filtersNotReady: "The fixture's compact-filter index did not reach its tip within 30 seconds."
            }
        }
    }

    public static func prepareBank() async throws {
        try requireSignet()
        try BitcoinCLI.ensureWallet(bank)
        if try BitcoinCLI.trustedBalanceSats(wallet: bank) < minimumBalance {
            let payout = try AddressDecoder.scriptPubKey(for: BitcoinCLI.newAddress(wallet: bank), network: .signet)
            for _ in 0 ..< 101 { try await SignetMiner.mineOntoTip(payingTo: payout) }
        }
        try requirePreparedBank()
        try await waitForFilters()
    }

    /// A fast UI-test precondition; mining belongs to the host preparation step.
    public static func requirePreparedBank() throws {
        try requireSignet()
        guard try BitcoinCLI.trustedBalanceSats(wallet: bank) >= minimumBalance else {
            throw FixtureError.bankNotPrepared
        }
    }

    private static func requireSignet() throws {
        let chain = try BitcoinCLI.runObject(["getblockchaininfo"])
        guard chain["chain"] as? String == "signet" else { throw FixtureError.wrongChain }
    }

    /// A connected block can precede its asynchronous compact-filter index.
    /// Do not launch the app against an incompletely prepared initial chain.
    private static func waitForFilters() async throws {
        let chain = try BitcoinCLI.runObject(["getblockchaininfo"])
        let height = try BitcoinCLI.int(chain, "blocks")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            let indexes = try BitcoinCLI.runObject(["getindexinfo"])
            if let basic = indexes["basic block filter index"] as? [String: Any],
               basic["synced"] as? Bool == true,
               try BitcoinCLI.int(basic, "best_block_height") >= height {
                return
            }
            guard ContinuousClock.now < deadline else { throw FixtureError.filtersNotReady }
            try await Task.sleep(for: .milliseconds(100))
        } while true
    }
}
