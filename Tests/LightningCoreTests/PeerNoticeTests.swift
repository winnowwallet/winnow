import Foundation
import XCTest
@testable import LightningCore

private final class NoticeJournal: LightningJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func load() -> Data? { lock.withLock { bytes } }
    func store(_ snapshot: Data) { lock.withLock { bytes = snapshot } }
}

final class PeerNoticeTests: XCTestCase, @unchecked Sendable {
    private func message(type: UInt16, channel: Data = Data(repeating: 0, count: 32),
                         data: Data) throws -> LightningWire.Message {
        var writer = LightningWire.Writer(); writer.append(channel)
        writer.u16(UInt16(data.count)); writer.append(data)
        return try .init(type: type, payload: writer.data)
    }

    func testWarningIsRecordedWithoutThrowingAndErrorRetainsProviderReason() async throws {
        let engine = try LightningEngine(chain: Data(repeating: 7, count: 32), journal: NoticeJournal())
        let peer = try ChannelKeys.publicKey(secret: Data(repeating: 2, count: 32))
        let session = LightningPeerSession(engine: engine, peer: peer, host: "localhost", port: 9735, onEvents: { _ in })
        try await session.handlePeerNotice(message(type: 1, data: Data("temporary channel warning".utf8)))
        let warning = await session.lastPeerWarning
        XCTAssertEqual(warning, "Provider warning: temporary channel warning")
        do {
            try await session.handlePeerNotice(message(type: 17, data: Data("channel rejected".utf8)))
            XCTFail("A global provider error must stop publication")
        } catch { XCTAssertEqual(error.localizedDescription, "Provider error: channel rejected") }
    }

    func testUnknownChannelNoticeIsIgnoredAndTemporaryChannelIsRecognized() async throws {
        let engine = try LightningEngine(chain: Data(repeating: 7, count: 32), journal: NoticeJournal())
        let peer = try ChannelKeys.publicKey(secret: Data(repeating: 2, count: 32))
        let session = LightningPeerSession(engine: engine, peer: peer, host: "localhost", port: 9735, onEvents: { _ in })
        try await session.handlePeerNotice(message(type: 17, channel: Data(repeating: 3, count: 32), data: Data("unknown".utf8)))
        try await engine.chainCaughtUp(); try await engine.peerInitialized(peer, features: .channelOpening)
        let id = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000)
        do {
            try await session.handlePeerNotice(message(type: 17, channel: id, data: Data("opening rejected".utf8)))
            XCTFail()
        } catch { XCTAssertEqual(error.localizedDescription, "Provider error: opening rejected") }
        let channels = await engine.channels()
        XCTAssertEqual(channels.first?.id, id, "Diagnostics must not delete channel state")
    }

    func testUntrustedProviderTextIsBoundedAndNonPrintableDataIsHidden() throws {
        let long = try LightningPeerNotice(message(type: 1, data: Data(repeating: 65, count: 1000)))
        XCTAssertEqual(long.detail.count, 240)
        for bytes in [Data([0]), Data("reason\nforged log".utf8), Data([0xff])] {
            XCTAssertEqual(try LightningPeerNotice(message(type: 17, data: bytes)).description, "Provider error")
        }
        XCTAssertEqual(try LightningPeerNotice(message(type: 17, data: Data())).description, "Provider error")
    }

    func testTruncatedPeerNoticeIsRejected() throws {
        let complete = try message(type: 1, data: Data("warning".utf8))
        for length in [0, 31, 32, 33, complete.payload.count - 1] {
            XCTAssertThrowsError(try LightningPeerNotice(.init(type: 1, payload: complete.payload.prefix(length))))
        }
    }
    func testRejectedOpeningDoesNotReplayAfterReconnectOrRestart() async throws {
        let journal = NoticeJournal(), chain = Data(repeating: 7, count: 32)
        let engine = try LightningEngine(chain: chain, journal: journal)
        let peer = try ChannelKeys.publicKey(secret: Data(repeating: 2, count: 32))
        let other = try ChannelKeys.publicKey(secret: Data(repeating: 3, count: 32))
        try await engine.chainCaughtUp()
        try await engine.peerInitialized(peer, features: .channelOpening)
        try await engine.peerInitialized(other, features: .channelOpening)
        let rejected = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000)
        let retained = try await engine.openChannel(peer: other, capacitySat: 100_000, feePerKW: 1000)
        let session = LightningPeerSession(engine: engine, peer: peer, host: "localhost", port: 9735, onEvents: { _ in })
        try await session.handlePeerNotice(message(type: 1, channel: rejected, data: Data("temporary".utf8)))
        let warningChannels = await engine.channels()
        XCTAssertEqual(warningChannels.first?.phase, .opening)
        do {
            try await session.handlePeerNotice(message(type: 17, channel: rejected, data: Data("below minimum".utf8)))
            XCTFail()
        } catch { XCTAssertEqual(error.localizedDescription, "Provider error: below minimum") }
        let channels = await engine.channels()
        XCTAssertEqual(channels.first(where: { $0.id == rejected })?.phase, .closed)
        XCTAssertEqual(channels.first(where: { $0.id == retained })?.phase, .opening)
        await engine.peerDisconnected(peer)
        try await engine.peerInitialized(peer, features: .channelOpening)
        let pending = try await engine.pendingMessages(peer: peer)
        XCTAssertTrue(pending.isEmpty)
        let restored = try LightningEngine(chain: chain, journal: journal)
        try await restored.chainCaughtUp(); try await restored.peerInitialized(peer, features: .channelOpening)
        let replayed = try await restored.pendingMessages(peer: peer)
        XCTAssertTrue(replayed.isEmpty, "A rejected unfunded request must not return after a process restart")
        let balances = try await restored.channelBalances()
        XCTAssertTrue(balances.isEmpty)
    }
}
