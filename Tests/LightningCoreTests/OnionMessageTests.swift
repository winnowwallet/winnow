import Foundation
import XCTest
@testable import LightningCore

final class OnionMessageTests: XCTestCase {
    private func secret(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
    private func key(_ byte: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: secret(byte)) }
    func testBlindedRoutePrefixLargePacketAndAuthenticatedReply() throws {
        let context = Data("static invoice response for persisted payment ID".utf8)
        let destination = try OnionMessage.path(nodes: [key(2), key(3)], context: context, authenticationKey: secret(9))
        let reply = try OnionMessage.path(nodes: [key(4)], context: Data([42]), authenticationKey: secret(10))
        let content = LightningWire.TLV(type: 70, value: Data(repeating: 77, count: 2000))
        let message = try OnionMessage.create(to: destination, via: [key(1)], content: content, reply: reply)
        XCTAssertEqual(message.payload.count, 32869)
        guard case .forward(.node(let second), let forwarded) = try OnionMessage.peel(message, nodeSecret: secret(1), authenticationKey: secret(9)) else { return XCTFail() }
        XCTAssertEqual(second, try key(2))
        guard case .forward(.node(let third), let final) = try OnionMessage.peel(forwarded, nodeSecret: secret(2), authenticationKey: secret(9)) else { return XCTFail() }
        XCTAssertEqual(third, try key(3))
        guard case .receive(let received, let receivedContext, let receivedReply) = try OnionMessage.peel(final, nodeSecret: secret(3), authenticationKey: secret(9)) else { return XCTFail() }
        XCTAssertEqual(received, content); XCTAssertEqual(receivedContext, context); XCTAssertEqual(receivedReply, reply)
        XCTAssertThrowsError(try OnionMessage.peel(final, nodeSecret: secret(3), authenticationKey: secret(8)))
        var corrupt = final.payload; corrupt[corrupt.endIndex - 1] ^= 1
        XCTAssertThrowsError(try OnionMessage.peel(.init(type: 513, payload: corrupt), nodeSecret: secret(3), authenticationKey: secret(9)))
    }
    func testKnowingNodeAndContextDoesNotAuthorizeForgedReply() throws {
        let forged = try OnionMessage.path(nodes: [key(3)], context: Data("payment ID".utf8), authenticationKey: secret(8))
        let message = try OnionMessage.create(to: forged, content: .init(type: 74, value: Data([0])))
        XCTAssertThrowsError(try OnionMessage.peel(message, nodeSecret: secret(3), authenticationKey: secret(9)))
        XCTAssertThrowsError(try OnionMessage.create(to: forged, content: .init(type: 2, value: Data())))
    }
}
