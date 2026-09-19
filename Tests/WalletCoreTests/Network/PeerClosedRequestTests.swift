import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Requests after peer teardown", .timeLimit(.minutes(2)))
struct PeerClosedRequestTests {
    @Test("a closed peer fails without waiting for its response deadline", arguments: [false, true])
    func closedPeerDoesNotWait(collectMany: Bool) async {
        let peer = PeerConnection(endpoint: PeerEndpoint(host: "127.0.0.1", port: 1), params: .signet)
        await peer.disconnect()
        let completed = EventCollector<Bool>()
        let request = Task {
            defer { completed.add(true) }
            do {
                if collectMany {
                    _ = try await peer.requestMany(.ping(1), expecting: "pong", count: 1, timeout: .seconds(90))
                } else {
                    _ = try await peer.request(.ping(1), expecting: ["pong"], timeout: .seconds(90))
                }
                Issue.record("a closed peer accepted a request")
            } catch let error as PeerError {
                #expect(error == .notConnected)
            } catch { Issue.record("unexpected error: \(error)") }
        }
        // The normal hang guard expires while the peer's response timer is
        // still pending, so a timeout cannot make this ordering check pass.
        #expect(await pollUntil { !completed.events.isEmpty })
        await request.value
    }
}
