@testable import WinnowApp
import CryptoKit
import WalletCore
import Foundation
import TestSupport
import XCTest

/// Fixtures shared across AppTests. What conforms to an app protocol has to
/// live here rather than in the package's TestSupport library.

/// A device authenticator that always approves, so a model can be driven
/// without a passcode prompt.
final class SilentAuthenticator: DeviceAuthenticating {
    func authenticate(reason: String) async throws {}
}

extension XCTestCase {
    /// Each test owns its preferences; teardown removes the whole suite.
    func makeDefaults() -> UserDefaults {
        let name = "winnow-tests-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
        }
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    func makeModel(network: BitcoinNetwork? = nil, defaults: UserDefaults? = nil,
                   deviceAuthenticator: any DeviceAuthenticating = SilentAuthenticator()) -> AppModel {
        let defaults = defaults ?? makeDefaults()
        if let network { defaults.set(network.rawValue, forKey: AppModel.DefaultsKey.network) }
        return AppModel(deviceAuthenticator: deviceAuthenticator, e2e: nil, defaults: defaults,
                        storeKeys: InMemoryStoreKeyVault())
    }
}

/// Store seal keys held in memory. The tests have no keychain namespace of
/// their own to leave items in, and a key that outlived its test would turn
/// the next test's fresh pre-seal fixture into a refusal. Each test makes one
/// and hands it to every store that must read what another wrote.
final class InMemoryStoreKeyVault: StoreKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]

    func key(for account: String) throws -> SymmetricKey? {
        lock.withLock { keys[account] }
    }

    func establishKey(for account: String) throws -> SymmetricKey {
        try lock.withLock {
            guard keys[account] == nil else { throw StoreKeyVaultError.alreadyEstablished(account) }
            let key = SymmetricKey(size: .bits256)
            keys[account] = key
            return key
        }
    }

    func discardKey(for account: String) throws {
        lock.withLock { keys[account] = nil }
    }
}

/// The JSON a store wrote, with the seal's header line taken off, for the
/// tests that read a store file back.
func unsealedPayload(of url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard SealedStoreFile.isSealed(data), let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
        return data
    }
    return Data(data[data.index(after: newline)...])
}

/// A signed transaction the broadcaster will accept, so a real relay entry can
/// be written and then damaged, confirmed or rolled back. Shaped like a signed
/// transaction rather than being one: nothing on this side checks a witness.
let signedTransactionBytes: Data = makeFakeSegwitTx().serialized(includeWitness: true)
