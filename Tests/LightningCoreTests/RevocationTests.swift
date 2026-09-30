import Foundation
import XCTest
@testable import LightningCore

final class RevocationTests: XCTestCase {
    func testAllPublishedStorageVectors() throws {
        struct Vector: Decodable {
            struct Step: Decodable { let index: UInt64; let secret: String; let valid: Bool }
            let name: String; let steps: [Step]
        }
        let vectors: [Vector] = try loadVectors("bolt3-storage")
        XCTAssertEqual(vectors.count, 9)
        for vector in vectors {
            var store = RevocationSecrets()
            var accepted: [Data] = []
            for step in vector.steps {
                let secret = try hex(step.secret)
                let number = ChannelKeys.maximumCommitmentNumber - step.index
                if step.valid {
                    try store.insert(secret: secret, commitmentNumber: number)
                    accepted.append(secret)
                } else {
                    XCTAssertThrowsError(try store.insert(secret: secret, commitmentNumber: number), vector.name)
                }
                XCTAssertEqual(store.received, UInt64(accepted.count), vector.name)
                for (index, previous) in accepted.enumerated() {
                    XCTAssertEqual(try store.secret(for: UInt64(index)), previous, vector.name)
                }
            }
        }
    }

    func testOutOfOrderAndInvalidSecretsDoNotAdvanceState() throws {
        var store = RevocationSecrets()
        let seed = Data(repeating: 42, count: 32)
        XCTAssertThrowsError(try store.secret(for: 0))
        XCTAssertThrowsError(try store.insert(secret: Data(repeating: 1, count: 32), commitmentNumber: 1))
        XCTAssertThrowsError(try store.insert(secret: Data(), commitmentNumber: 0))
        for number in 0..<1024 {
            try store.insert(secret: ChannelKeys.commitmentSecret(seed: seed, number: UInt64(number)),
                             commitmentNumber: UInt64(number))
        }
        XCTAssertThrowsError(try store.insert(secret: Data(repeating: 1, count: 32), commitmentNumber: 1023))
        XCTAssertThrowsError(try store.secret(for: 1024))
        for number in 0..<1024 {
            XCTAssertEqual(try store.secret(for: UInt64(number)),
                           try ChannelKeys.commitmentSecret(seed: seed, number: UInt64(number)))
        }
    }
}
