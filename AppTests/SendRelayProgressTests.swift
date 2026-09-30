@testable import WinnowApp
import Foundation
import WalletCore
import XCTest

@MainActor
final class SendRelayProgressTests: XCTestCase {
    private let watched = Data(repeating: 0x41, count: 32)
    private let unrelated = Data(repeating: 0x42, count: 32)
    private let peer = PeerEndpoint(host: "127.0.0.1", port: 9735)

    func testAnotherTransactionsEventsCannotAlterThePaymentReceipt() {
        var progress = SendRelayProgress()
        let original = progress
        let events: [TxBroadcaster.Event] = [
            .announced(txid: unrelated, peerCount: 7),
            .requested(txid: unrelated, peer: peer),
            .feeFloorExceeded(txid: unrelated, floor: 50_000),
            .confirmed(txid: unrelated)
        ]
        for event in events {
            XCTAssertFalse(progress.apply(event, txid: watched, confirmationHeight: 120))
            XCTAssertEqual(progress, original)
        }
    }

    func testPeerEchoAndRepeatedRequestsOnlyCountOneRelay() {
        var progress = SendRelayProgress()
        XCTAssertFalse(progress.apply(.announced(txid: watched, peerCount: 3), txid: watched, confirmationHeight: nil))
        let request = TxBroadcaster.Event.requested(txid: watched, peer: peer)
        XCTAssertFalse(progress.apply(request, txid: watched, confirmationHeight: nil))
        XCTAssertFalse(progress.apply(request, txid: watched, confirmationHeight: nil))
        XCTAssertEqual(progress.peers, [peer.description])
        XCTAssertEqual(progress.log, ["Announced to 3 peer(s)", "Relayed to \(peer)"])

        let echoedPeer = PeerEndpoint(host: "127.0.0.2", port: 9735)
        progress.peers.insert(echoedPeer.description)
        XCTAssertFalse(progress.apply(.requested(txid: watched, peer: echoedPeer), txid: watched, confirmationHeight: nil))
        XCTAssertEqual(progress.peers.count, 2)
        XCTAssertEqual(progress.log.count, 2, "A mempool echo and broadcaster request describe the same relay")
    }

    func testConfirmationEndsTrackingBeforePendingHistoryIsRefreshed() {
        var progress = SendRelayProgress()
        XCTAssertFalse(progress.apply(.feeFloorExceeded(txid: watched, floor: 50_000), txid: watched, confirmationHeight: nil))
        XCTAssertTrue(progress.feeFloorNotice)
        XCTAssertTrue(progress.apply(.confirmed(txid: watched), txid: watched, confirmationHeight: nil))
        XCTAssertNil(progress.confirmedHeight)
        XCTAssertTrue(progress.apply(.confirmed(txid: watched), txid: watched, confirmationHeight: 0))
        XCTAssertNil(progress.confirmedHeight)
        XCTAssertTrue(progress.apply(.confirmed(txid: watched), txid: watched, confirmationHeight: 120))
        XCTAssertEqual(progress.confirmedHeight, 120)
    }

    func testOtherBroadcasterEventsDoNotClaimRelayOrConfirmation() {
        var progress = SendRelayProgress()
        let events: [TxBroadcaster.Event] = [
            .served(txid: watched, peer: peer),
            .failed(txid: watched, peer: peer, reason: "Disconnected"),
            .deprioritized(txid: watched, peer: peer),
            .cancelled(txid: watched),
            .persistenceFailed(reason: "Storage unavailable")
        ]
        for event in events {
            XCTAssertFalse(progress.apply(event, txid: watched, confirmationHeight: 120))
            XCTAssertEqual(progress, SendRelayProgress())
        }
    }
}
