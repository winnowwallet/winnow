@testable import WinnowApp
import Foundation
import TestSupport
import WalletCore
import XCTest

@MainActor
final class ReceiveAddressLabelTests: XCTestCase {
    private let address = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    private let otherAddress = "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"

    private func file() -> URL {
        let url = tempFileURL("receive-labels.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testLabelsPersistByExactAddressAndCanBeRenamedOrRemoved() throws {
        let url = file()
        let store = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet)
        let script = try AddressDecoder.scriptPubKey(for: address, network: .mainnet)
        let otherScript = try AddressDecoder.scriptPubKey(for: otherAddress, network: .mainnet)
        try store.setLabel("  Alice / invoice 12  ", address: address)
        XCTAssertEqual(store.labels[script], "Alice / invoice 12")
        XCTAssertNil(store.labels[otherScript], "another address must start unlabeled")
        try store.setLabel("Bob", address: otherAddress)
        let reopened = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet)
        XCTAssertEqual(reopened.labels, [script: "Alice / invoice 12", otherScript: "Bob"])
        try reopened.setLabel("Alice / paid", address: address)
        try reopened.setLabel("", address: otherAddress)
        let final = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet)
        XCTAssertEqual(final.labels, [script: "Alice / paid"])
    }

    func testFailedWritePreservesTheFileAndLiveLabels() throws {
        enum Failure: Error { case expected }
        let url = file()
        let store = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet)
        try store.setLabel("Original", address: address)
        let original = try Data(contentsOf: url)
        let failing = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet,
                                               writeData: { _, _ in throw Failure.expected })
        XCTAssertThrowsError(try failing.setLabel("Changed", address: address))
        XCTAssertThrowsError(try failing.setLabel("", address: address))
        XCTAssertEqual(failing.labels, store.labels)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testWrongWalletNetworkAndUnknownSchemaDoNotLeakOrOverwriteLabels() throws {
        let url = file()
        let store = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet)
        try store.setLabel("Private note", address: address)
        let original = try Data(contentsOf: url)
        for (walletID, network) in [("two", BitcoinNetwork.mainnet), ("one", .signet)] {
            let wrong = ReceiveAddressLabelStore(storageURL: url, walletID: walletID, network: network)
            XCTAssertTrue(wrong.labels.isEmpty)
            XCTAssertNotNil(wrong.notice)
            XCTAssertThrowsError(try wrong.setLabel("Overwritten", address: address))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["version"] = 2
        let unknown = try JSONSerialization.data(withJSONObject: json)
        try unknown.write(to: url)
        let rejected = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet)
        XCTAssertTrue(rejected.labels.isEmpty)
        XCTAssertThrowsError(try rejected.setLabel("Changed", address: address))
        XCTAssertEqual(try Data(contentsOf: url), unknown)
    }

    func testInvalidOrOversizedStorageIsNotPartiallyLoaded() throws {
        let url = file()
        let key = try AddressDecoder.scriptPubKey(for: address, network: .mainnet).hex
        let invalidRecord = try JSONSerialization.data(withJSONObject: [
            "version": 1, "walletID": "one", "network": "mainnet",
            "labels": [key: "Valid", "invalid": "Invalid"]
        ])
        for bytes in [Data("not json".utf8), invalidRecord,
                      Data(repeating: 32, count: ReceiveAddressLabelStore.maximumFileBytes + 1)] {
            try bytes.write(to: url)
            let store = ReceiveAddressLabelStore(storageURL: url, walletID: "one", network: .mainnet)
            XCTAssertTrue(store.labels.isEmpty)
            XCTAssertNotNil(store.notice)
            XCTAssertThrowsError(try store.setLabel("New", address: address))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testLabelBoundsAndNetworkValidation() throws {
        let store = ReceiveAddressLabelStore(storageURL: file(), walletID: "one", network: .mainnet)
        for text in [String(repeating: "a", count: 121), "Alice\nBob", "Alice\u{202E}Bob"] {
            XCTAssertThrowsError(try store.setLabel(text, address: address))
        }
        XCTAssertTrue(store.labels.isEmpty)
        try store.setLabel(String(repeating: "a", count: 120), address: address)
        XCTAssertThrowsError(try store.setLabel("Bad address", address: "garbage"))
        let signet = ReceiveAddressLabelStore(storageURL: file(), walletID: "one", network: .signet)
        XCTAssertThrowsError(try signet.setLabel("Wrong network", address: address))
        let unavailable = ReceiveAddressLabelStore(storageURL: nil, walletID: "one", network: .mainnet)
        XCTAssertThrowsError(try unavailable.setLabel("Not persisted", address: address))
    }

    func testAddressAliasesHaveOneLabel() async throws {
        let wallet = try makeTestWallet()
        let bech32 = try await wallet.address(chain: .receive, index: 0)
        let store = ReceiveAddressLabelStore(storageURL: file(), walletID: "one", network: .signet)
        try store.setLabel("First", address: bech32)
        try store.setLabel("Renamed", address: bech32.uppercased())
        XCTAssertEqual(store.labels.count, 1)
        XCTAssertEqual(store.labels.values.first, "Renamed")
    }

    func testHistoryUsesExactOwnedOutputsWithoutInventingASender() throws {
        let scripts = try [address, otherAddress].map { try AddressDecoder.scriptPubKey(for: $0, network: .mainnet) }
        let tx = Transaction(version: 2, inputs: [Transaction.Input(
            previousOutput: Transaction.Outpoint(txid: Data(repeating: 1, count: 32), vout: 0),
            scriptSig: Data(), sequence: .max)],
            outputs: [Transaction.Output(value: 1_000, scriptPubKey: scripts[0]),
                      Transaction.Output(value: 2_000, scriptPubKey: scripts[1]),
                      Transaction.Output(value: 3_000, scriptPubKey: scripts[0])], locktime: 0)
        var entry = HistoryEntry(txid: tx.txid, height: 10, received: 6_000, spent: 0,
                                 rawTransaction: tx.serialized(includeWitness: false))
        let labels = [scripts[0]: "Invoice 12", scripts[1]: "Refund"]
        let matches = AppModel.labeledReceiveOutputs(entry, labels: labels, owned: Set(scripts), network: .mainnet)
        XCTAssertEqual(matches.map(\.label), ["Invoice 12", "Refund", "Invoice 12"])
        XCTAssertEqual(matches.map(\.amount), [1_000, 2_000, 3_000])
        XCTAssertEqual(matches.map(\.id), [0, 1, 2])
        XCTAssertEqual(AppModel.labeledReceiveOutputs(entry, labels: labels, owned: [scripts[1]], network: .mainnet).map(\.label), ["Refund"])
        XCTAssertTrue(AppModel.paymentRecipients(entry, owned: Set(scripts), people: [:], network: .mainnet).isEmpty)
        entry.rawTransaction = nil
        XCTAssertTrue(AppModel.labeledReceiveOutputs(entry, labels: labels, owned: Set(scripts), network: .mainnet).isEmpty,
                      "old history without outputs cannot be guessed from the total")
        entry.rawTransaction = Data([0])
        XCTAssertTrue(AppModel.labeledReceiveOutputs(entry, labels: labels, owned: Set(scripts), network: .mainnet).isEmpty)
    }

    func testModelKeepsLabelsOnOldAddressesAfterRotationAndRelaunch() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "receive-labels-\(UUID().uuidString)",
                           "WINNOW_E2E_ENTROPY": String(repeating: "a1", count: 16)]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, new in new })
        else { return XCTFail("no isolated receive-label fixture") }
        defer { cleanup.wipeIfRequested() }
        let model = AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: mode, defaults: makeDefaults())
        let directory = try XCTUnwrap(model.storageDirectory())
        _ = try Wallet.create(network: .signet, keyStore: model.keyStore,
                              storageURL: directory.appending(path: "wallet.json"), entropy: mode.entropy)
        await model.boot()
        let old = try await model.currentReceiveAddress()
        try await model.setReceiveAddressLabel("Alice", address: old)
        let fresh = try await model.freshReceiveAddress()
        XCTAssertNotEqual(old, fresh)
        XCTAssertNil(model.receiveAddressLabel(for: fresh))
        XCTAssertEqual(model.receiveAddressLabel(for: old), "Alice")
        try await model.setReceiveAddressLabel("Alice / edited", address: old)
        let reopened = AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: mode, defaults: makeDefaults())
        await reopened.boot()
        let reopenedAddress = try await reopened.currentReceiveAddress()
        XCTAssertEqual(reopenedAddress, fresh)
        XCTAssertEqual(reopened.receiveAddressLabel(for: old), "Alice / edited")
        XCTAssertTrue(reopened.people.isEmpty, "an own-address note must not create a payable contact")
        let strangerWallet = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(), entropy: Data(repeating: 0xB2, count: 16))
        let stranger = try await strangerWallet.address(chain: .receive, index: 0)
        do {
            try await reopened.setReceiveAddressLabel("Not ours", address: stranger)
            XCTFail("a foreign address was labeled as ours")
        } catch AppModel.AppError.noWallet { }
    }
}
