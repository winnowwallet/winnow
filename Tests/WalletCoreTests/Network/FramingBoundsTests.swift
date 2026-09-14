import Foundation
import Testing
@testable import WalletCore

/// The framer must not keep what it has already handed out. `removeFirst`
/// on `Data` reslices instead of freeing, so without compaction a
/// connection's buffer grows with every byte it has ever received (IR-025:
/// +257 MB resident after 256 MB of valid frames). These pin the repair.
@Suite("Framing bounds")
struct FramingBoundsTests {
    private let magic = NetworkParams.signet.magic

    private func pingFrame() -> Data {
        MessageFramer.frame(command: "ping", payload: PeerMessage.ping(7).payload, magic: magic)
    }

    @Test("consumed frames are released once the drain loop compacts")
    func compactionReleasesConsumedFrames() throws {
        var framer = MessageFramer(magic: magic)
        var chunk = Data()
        for _ in 0 ..< 1_000 { chunk.append(pingFrame()) }
        framer.append(chunk)
        var decoded = 0
        while try framer.nextMessage() != nil { decoded += 1 }
        #expect(decoded == 1_000)
        // The defect: everything is consumed, yet the storage still starts
        // a chunk's worth in.
        #expect(framer.bufferedCount == 0)
        #expect(framer.bufferStartIndex == chunk.count)
        framer.compact()
        #expect(framer.bufferStartIndex == 0)
        #expect(framer.bufferedCount == 0)
    }

    @Test("compaction keeps a partial frame and the next message still decodes")
    func compactionKeepsPartialFrame() throws {
        var framer = MessageFramer(magic: magic)
        let frame = pingFrame()
        var chunk = frame
        chunk.append(frame.prefix(10))
        framer.append(chunk)
        #expect(try framer.nextMessage()?.command == "ping")
        #expect(try framer.nextMessage() == nil)
        framer.compact()
        #expect(framer.bufferStartIndex == 0)
        #expect(framer.bufferedCount == 10)
        framer.append(frame.dropFirst(10))
        #expect(try framer.nextMessage()?.command == "ping")
        #expect(try framer.nextMessage() == nil)
    }

    @Test("compacting an untouched buffer is a no-op")
    func compactionNoOp() {
        var framer = MessageFramer(magic: magic)
        framer.compact()
        #expect(framer.bufferedCount == 0)
        framer.append(pingFrame().prefix(5))
        framer.compact()
        #expect(framer.bufferedCount == 5)
        #expect(framer.bufferStartIndex == 0)
    }
}
