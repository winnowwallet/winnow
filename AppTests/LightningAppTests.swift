@testable import WinnowApp
import CryptoKit
import LightningCore
import Security
import TestSupport
import WalletCore
import XCTest

@MainActor
final class LightningAppTests: XCTestCase {
    private final class Denied: DeviceAuthenticating {
        var attempts = 0
        func authenticate(reason: String) async throws { attempts += 1; throw CancellationError() }
    }
    private final class Pending: DeviceAuthenticating {
        var entered: (() -> Void)?
        var continuation: CheckedContinuation<Void, any Error>?
        func authenticate(reason: String) async throws {
            try await withCheckedThrowingContinuation { continuation = $0; entered?() }
        }
    }
    private func key(_ seed: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: seed, count: 32)) }
    private func profile() throws -> LightningProfile {
        try LightningProfile(network: "regtest", name: "Fixture", peer: key(21).hex, host: "127.0.0.1", port: 1,
            route: .init(introduction: key(22).hex, shortChannelID: 1, baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48), receive: nil)
    }
    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lightning-app-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func prepared(_ dir: URL, keys: InMemoryStoreKeyVault = .init()) async throws -> LightningAppController {
        let controller = LightningAppController(network: .regtest, keys: keys)
        try await controller.prepare(directory: dir, headers: HeaderChain(params: .regtest))
        return controller
    }
    private func review(_ profile: LightningProfile) throws -> LightningAppController.PaymentReview {
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([
            .init(type: 2, value: NetworkParams.regtest.genesisHash), .init(type: 22, value: key(23))]))
        let request = try LightningEngine.OfferPayment(id: Data(repeating: 1, count: 32), channelID: Data(repeating: 2, count: 32),
            offer: offer, amountMsat: 5000, feeLimitMsat: 1000, route: XCTUnwrap(profile.paymentRoute()))
        return .init(request: request, profile: profile, offerText: offer.string)
    }
    func testCancelledProviderReviewLeavesNoProfileOrJournalMutation() async throws {
        let dir = directory(), controller = try await prepared(dir), auth = Denied()
        let before = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        do { try await controller.saveProfile(profile(), model: makeModel(network: .regtest, deviceAuthenticator: auth)); XCTFail("canceled review saved a provider") }
        catch is CancellationError {}
        XCTAssertEqual(auth.attempts, 1)
        XCTAssertNil(controller.profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "lightning/profile.json").path))
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), before)
    }
    func testCancelledPaymentDoesNotCreatePaymentOrPublishIntent() async throws {
        let dir = directory(), controller = try await prepared(dir), profile = try profile(), auth = Denied()
        try await controller.saveProfile(profile, model: makeModel(network: .regtest))
        let model = makeModel(network: .regtest, deviceAuthenticator: auth)
        let before = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        do { try await controller.pay(review(profile), model: model); XCTFail("canceled authentication created payment") }
        catch is CancellationError {}
        XCTAssertEqual(auth.attempts, 1)
        XCTAssertFalse(model.keychainAuthentication.isGranted)
        XCTAssertTrue(controller.payments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), before)
    }
    private func invoiceReview(_ profile: LightningProfile) throws -> LightningAppController.InvoiceReview {
        let text = try Bolt11Invoice.encode(network: .regtest, amountMsat: 5000, hash: Data(repeating: 8, count: 32),
            secret: Data(repeating: 9, count: 32), nodeSecret: Data(repeating: 21, count: 32), route: nil, timestamp: UInt64(Date().timeIntervalSince1970))
        let invoice = try Bolt11Invoice.decode(text, network: .regtest), route = try Bolt11PaymentRoute(hops: [])
        let request = LightningEngine.InvoicePayment(id: Data(repeating: 3, count: 32), peer: profile.peerKey,
            channelID: Data(repeating: 2, count: 32), invoice: text, network: .regtest, amountMsat: 5000, feeLimitMsat: 0, maximumDelta: 144, route: route)
        return try .init(request: request, profile: profile,
            quote: route.quote(invoice: invoice, amountMsat: 5000, feeLimitMsat: 0, height: 0, maximumDelta: 144),
            description: invoice.description, payee: invoice.payee, expiresAt: invoice.expiresAt)
    }
    func testCancelledInvoiceAuthenticationCannotWritePayment() async throws {
        let dir = directory(), controller = try await prepared(dir), profile = try profile(), auth = Denied()
        try await controller.saveProfile(profile, model: makeModel(network: .regtest))
        let model = makeModel(network: .regtest, deviceAuthenticator: auth)
        let before = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        do { try await controller.payInvoice(invoiceReview(profile), model: model); XCTFail() } catch is CancellationError {}
        XCTAssertEqual(auth.attempts, 1); XCTAssertTrue(controller.payments.isEmpty)
        XCTAssertFalse(model.keychainAuthentication.isGranted)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), before)
    }
    func testInvoiceAuthenticationCannotApproveAfterControllerStops() async throws {
        let dir = directory(), controller = try await prepared(dir), profile = try profile(), auth = Pending()
        try await controller.saveProfile(profile, model: makeModel(network: .regtest))
        let model = makeModel(network: .regtest, deviceAuthenticator: auth), request = try invoiceReview(profile)
        let entered = expectation(description: "invoice authentication pending"); auth.entered = { entered.fulfill() }
        let before = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        let operation = Task { try await controller.payInvoice(request, model: model) }
        await fulfillment(of: [entered], timeout: 5)
        await controller.stop(); auth.continuation?.resume(); auth.continuation = nil
        do { try await operation.value; XCTFail() } catch is CancellationError {}
        XCTAssertTrue(controller.payments.isEmpty); XCTAssertFalse(model.keychainAuthentication.isGranted)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), before)
    }

    func testProviderAuthenticationCannotCompleteAfterTheControllerStops() async throws {
        let dir = directory(), controller = try await prepared(dir), auth = Pending()
        let model = makeModel(network: .regtest, deviceAuthenticator: auth)
        let entered = expectation(description: "provider authentication pending")
        auth.entered = { entered.fulfill() }
        let proposed = try profile()
        let operation = Task { try await controller.saveProfile(proposed, model: model) }
        await fulfillment(of: [entered], timeout: 5)
        await controller.stop()
        auth.continuation?.resume(); auth.continuation = nil
        do { try await operation.value; XCTFail("stale review saved after network/lifecycle change") }
        catch is CancellationError {}
        XCTAssertNil(controller.profile)
        XCTAssertFalse(model.keychainAuthentication.isGranted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "lightning/profile.json").path))
    }
    func testDuplicatePaymentTapSharesWalletSpendingExclusion() async throws {
        let controller = try await prepared(directory()), profile = try profile()
        try await controller.saveProfile(profile, model: makeModel(network: .regtest))
        let auth = Pending(), model = makeModel(network: .regtest, deviceAuthenticator: auth), request = try review(profile)
        let entered = expectation(description: "authentication pending")
        auth.entered = { entered.fulfill() }
        let first = Task { try await controller.pay(request, model: model) }
        await fulfillment(of: [entered], timeout: 5)
        do { try await controller.pay(request, model: model); XCTFail("second tap entered authentication") }
        catch AppModel.AppError.spendAlreadyInFlight {}
        do { try await model.exclusively(.spending) {}; XCTFail("on-chain send raced Lightning authentication") }
        catch AppModel.AppError.spendAlreadyInFlight {}
        auth.continuation?.resume(throwing: CancellationError()); auth.continuation = nil
        do { try await first.value; XCTFail() } catch is CancellationError {}
        try await model.exclusively(.spending) {}
        XCTAssertTrue(controller.payments.isEmpty)
    }
    private func createIdentity(_ dir: URL, keys: InMemoryStoreKeyVault) async throws -> String {
        try await prepared(dir, keys: keys).nodeID
    }
    func testIdentityIsDurableBeforeProviderRegistrationAndStartsPaused() async throws {
        let dir = directory(), keys = InMemoryStoreKeyVault()
        let id = try await createIdentity(dir, keys: keys)
        let reopened = try await prepared(dir, keys: keys)
        XCTAssertEqual(reopened.nodeID, id)
        XCTAssertFalse(reopened.chainCurrent)
    }
    func testJournalFileProtectionWhenPlatformRecordsIt() async throws {
        // Same measured platform capability as the existing WalletCore file
        // protection suite. This is a required physical-device release check.
        try XCTSkipUnless(fileProtectionRecorded, "This simulator does not record file protection classes; verify on a physical device")
        let dir = directory()
        _ = try await prepared(dir)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "lightning/journal.v1").path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }
    func testMissingJournalOrKeyNeverCreatesReplacementIdentity() async throws {
        let dir = directory(), keys = InMemoryStoreKeyVault()
        _ = try await createIdentity(dir, keys: keys)
        let bytes = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        do { _ = try await prepared(dir); XCTFail("missing key was replaced") }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), bytes)
        try FileManager.default.removeItem(at: dir.appending(path: "lightning/journal.v1"))
        do { _ = try await prepared(dir, keys: keys); XCTFail("missing journal was replaced") }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "lightning/journal.v1").path))
    }
    func testInvalidOffersAndReviewBoundsFailBeforePayment() throws {
        for text in ["", "lnbc123", "lno1notanoffer", String(repeating: "x", count: 70_000)] {
            XCTAssertThrowsError(try LightningAppController.validateOffer(text, network: .regtest, amountSat: 5000, maximumFeeSat: 50, now: 1))
        }
        XCTAssertThrowsError(try LightningAppController.validateOffer("", network: .regtest, amountSat: .max, maximumFeeSat: 0, now: 1))
        var value = try JSONEncoder().encode(profile())
        let string = String(decoding: value, as: UTF8.self).replacingOccurrences(of: "regtest", with: "mainnet")
        value = Data(string.utf8)
        XCTAssertThrowsError(try LightningProfile.parse(String(decoding: value, as: UTF8.self), network: .regtest))
    }
    func testJournalKeyRequestsDeviceOnlyWhenUnlockedProtection() throws {
        let service = "winnow-lightning-key-test-\(UUID().uuidString)", account = "journal"
        let vault = KeychainStoreKeyVault(service: service, protection: .whenUnlocked)
        defer { try? vault.discardKey(for: account) }
        _ = try vault.establishKey(for: account)
        var result: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: KeychainStoreKeyVault.accountPrefix + account, kSecReturnAttributes: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [CFString: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable] as? Bool, false)
    }

    func testResearchWalletCannotBeReplacedBeforeOrAfterBoot() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "preserve-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
            "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_NETWORK": "regtest"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create isolated research wallet") }
        defer { cleanup.wipeIfRequested() }
        let keys = InMemoryKeyStore(), auth = Denied()
        let model = AppModel(deviceAuthenticator: auth, e2e: mode,
                             storeKeys: InMemoryStoreKeyVault(), keyStore: keys)
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: mode.storageDirectoryName).appending(path: "regtest")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "wallet.json")
        let wallet = try Wallet.create(network: .regtest, keyStore: keys, storageURL: file, entropy: mode.entropy)
        let walletID = await wallet.id
        let original = try Data(contentsOf: file), secret = try keys.load(walletID: walletID).serialized
        let replacementDirectory = directory()
        try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
        let replacement = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(),
            storageURL: replacementDirectory.appending(path: "wallet.json"), entropy: Data(repeating: 7, count: 16))
        let bundle = try await replacement.exportBundle(includeMnemonic: false)
        let json = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
        let replacementID = await replacement.id
        XCTAssertNotEqual(walletID, replacementID)
        for booted in [false, true] {
            if booted { await model.boot(); XCTAssertEqual(model.walletID, walletID) }
            do { try await model.createWallet(); XCTFail("replaced research wallet") }
            catch AppModel.AppError.storageDamaged {}
            do { try await model.importWallet(bundleJSON: json); XCTFail("import replaced research wallet") }
            catch AppModel.AppError.storageDamaged {}
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try keys.load(walletID: walletID).serialized, secret)
        }
        XCTAssertEqual(auth.attempts, 0, "refuse replacement before requesting owner authentication")
        XCTAssertNil(model.stack, "replacement must not start networking")
    }
}
