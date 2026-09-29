@testable import WinnowApp
import Foundation
import LightningCore
import WalletCore
import XCTest

@MainActor
final class LightningNetworkTests: XCTestCase {
    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "lightning-networks-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func profile(_ network: BitcoinNetwork) throws -> LightningProfile {
        let key = try ChannelKeys.publicKey(secret: Data(repeating: 7, count: 32))
        return .init(network: network.rawValue, name: "Local test", peer: key.hex, host: "127.0.0.1", port: 1,
                     route: nil, receive: nil)
    }

    func testFreshInstallUsesMainnetAndOldWalletOrJournalKeepsRegtest() throws {
        for name in ["wallet.json", "lightning/journal.v1"] {
            let root = directory()
            XCTAssertEqual(LightningResearch.initialNetwork(root: root), .mainnet)
            let file = root.appending(path: "regtest/\(name)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
            XCTAssertEqual(LightningResearch.initialNetwork(root: root), .regtest)
            XCTAssertEqual(try Data(contentsOf: file), Data([1]))
        }
    }

    func testEveryNetworkKeepsIndependentDurableIdentityAndProfile() async throws {
        let root = directory(), keys = InMemoryStoreKeyVault()
        var ids: [BitcoinNetwork: String] = [:]
        for network in BitcoinNetwork.allCases {
            let controller = LightningAppController(network: network, keys: keys)
            try await controller.prepare(directory: root.appending(path: network.rawValue),
                                         headers: HeaderChain(params: .params(for: network)))
            let chain = await controller.engine?.chainHash()
            XCTAssertEqual(chain, NetworkParams.params(for: network).genesisHash)
            ids[network] = controller.nodeID
            try await controller.saveProfile(profile(network), model: makeModel(network: network))
        }
        XCTAssertEqual(Set(ids.values).count, 3)
        for network in BitcoinNetwork.allCases {
            let controller = LightningAppController(network: network, keys: keys)
            try await controller.prepare(directory: root.appending(path: network.rawValue),
                                         headers: HeaderChain(params: .params(for: network)))
            XCTAssertEqual(controller.nodeID, ids[network])
            XCTAssertEqual(controller.profile, try profile(network))
            XCTAssertFalse(controller.chainCurrent)
        }
        XCTAssertNotNil(try keys.key(for: "lightning-journal-v2"), "retain the shipped regtest key account")
    }

    func testRejectsCrossNetworkHeadersAndProfilesBeforeCreatingState() async throws {
        let root = directory(), keys = InMemoryStoreKeyVault()
        let controller = LightningAppController(network: .mainnet, keys: keys)
        do { try await controller.prepare(directory: root, headers: HeaderChain(params: .regtest)); XCTFail() }
        catch { XCTAssertEqual(error as? LightningError, .invalidHash) }
        XCTAssertNil(try keys.key(for: "lightning-journal-v2.mainnet"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        for network in BitcoinNetwork.allCases {
            let text = String(decoding: try JSONEncoder().encode(profile(network)), as: UTF8.self)
            XCTAssertEqual(try LightningProfile.parse(text, network: network).network, network.rawValue)
            for other in BitcoinNetwork.allCases where other != network {
                XCTAssertThrowsError(try LightningProfile.parse(text, network: other))
            }
        }
    }

    func testMainnetOffersReachValidationAndOtherNetworksAreRejected() throws {
        let key = try ChannelKeys.publicKey(secret: Data(repeating: 8, count: 32))
        let path = try BlindedPath(introduction: .node(key), blinding: key,
                                  hops: [.init(nodeID: key, encryptedData: Data([1]))])
        for network in BitcoinNetwork.allCases {
            let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([
                .init(type: 2, value: NetworkParams.params(for: network).genesisHash),
                .init(type: 16, value: path.encoded()), .init(type: 22, value: key)]))
            XCTAssertEqual(try LightningAppController.validateOffer(offer.string, network: network,
                amountSat: 1000, maximumFeeSat: 50, now: 1), offer)
            for other in BitcoinNetwork.allCases where other != network {
                XCTAssertThrowsError(try LightningAppController.validateOffer(offer.string, network: other,
                    amountSat: 1000, maximumFeeSat: 50, now: 1))
            }
        }
    }

    func testStaleNetworkEventsCannotUseTheCurrentWallet() async throws {
        let controller = LightningAppController(network: .regtest, keys: InMemoryStoreKeyVault())
        let mainnet = makeModel(network: .mainnet)
        do { try await controller.handle([], model: mainnet); XCTFail() }
        catch is CancellationError {}
        do { try await controller.saveProfile(profile(.regtest), model: mainnet); XCTFail() }
        catch is CancellationError {}
        let model = makeModel(network: .regtest), generation = controller.generation
        await controller.stop()
        XCTAssertThrowsError(try controller.requireNetwork(model, generation: generation))
    }

    func testCommitmentFeesUseWalletRatesWithoutTruncationOrOverflow() throws {
        XCTAssertEqual(try LightningAppController.commitmentFeeRate(satPerVByte: 20), 5000)
        XCTAssertEqual(try LightningAppController.commitmentFeeRate(satPerVByte: 1.013), 254)
        XCTAssertEqual(try LightningAppController.commitmentFeeRate(satPerVByte: 1), 253)
        for invalid in [Double.nan, .infinity, -1, 0, 401] {
            XCTAssertThrowsError(try LightningAppController.commitmentFeeRate(satPerVByte: invalid))
        }
    }
}
