import CryptoKit
import Foundation
import os
import Testing
@testable import CryptoResearch

@Suite("Fixed public-data cryptography research")
struct CryptoResearchTests {
    @Test("Pinned corpus is unchanged, complete, and contains public inputs only")
    func corpusIdentity() throws {
        let data = try CryptoResearchCorpus.data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "e2c1e6f7a544afc8b00bae9bbdc689dd0d818f872fe71da179b9605e4b0ef79c")
        let vectors = try CryptoResearchCorpus.load()
        #expect(vectors.count == 318)
        #expect(Set(vectors.map(\.x)).count == 306)
        #expect(vectors.filter { $0.name.hasPrefix("bip340-key-") }.count == 19)
        #expect(vectors.filter { $0.name.hasPrefix("boundary-") }.count == 43)
        #expect(vectors.filter { $0.name.hasPrefix("synthetic-") }.count == 256)
        #expect(vectors.filter { $0.evenY != nil }.count == 167)
        #expect(vectors.filter { $0.evenY == nil }.count == 151)
    }

    @Test("Every bundled reference agrees in both validity and the full even-y coordinate")
    func fullReferenceComparison() async throws {
        let report = try await CryptoResearchDemo.run()
        #expect(report.totalCount == 318)
        #expect(report.matchedCount == 318)
        #expect(report.mismatchCount == 0)
        #expect(report.validCaseCount == 167)
        #expect(report.invalidCaseCount == 151)
        #expect(report.fixtureRevision == "2ef204167972efc428486e823fc79b1f1bf0e9e7")
        #expect(report.results.allSatisfy { $0.passed })
    }

    @Test("Wrong acceptance and wrong coordinates remain visible as mismatches")
    func mismatchReporting() throws {
        let generator = try generatorVector()
        let rejected = try CryptoResearchRunner.run(vectors: [generator], evaluate: { _ in nil })
        #expect(rejected.mismatchCount == 1)
        #expect(rejected.results[0].expectedValid)
        #expect(!rejected.results[0].actualValid)
        #expect(rejected.results[0].expectedEvenYHex == generatorY)

        let wrongCoordinate = try CryptoResearchRunner.run(vectors: [generator], evaluate: { _ in
            Data(repeating: 0, count: 32)
        })
        #expect(wrongCoordinate.mismatchCount == 1)
        #expect(wrongCoordinate.results[0].actualValid)
        #expect(!wrongCoordinate.results[0].passed)
        #expect(wrongCoordinate.results[0].actualEvenYHex == String(repeating: "0", count: 64))

        let invalid = CryptoResearchVector(name: "x-equals-p", x: try CryptoResearchHex.decodeCoordinate(
            "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"
        ), evenY: nil)
        let falseAcceptance = try CryptoResearchRunner.run(vectors: [invalid], evaluate: { _ in
            Data(repeating: 0, count: 32)
        })
        #expect(falseAcceptance.mismatchCount == 1)
        #expect(!falseAcceptance.results[0].expectedValid)
        #expect(falseAcceptance.results[0].actualValid)
    }

    @Test("Malformed or missing fixtures throw instead of reporting a pass")
    func malformedFixtures() throws {
        #expect(throws: CryptoResearchError.missingFixture) {
            _ = try CryptoResearchCorpus.data(bundle: .main)
        }
        for invalid in [Data(), Data("not json".utf8), Data("[]".utf8)] {
            #expect(throws: CryptoResearchError.invalidFixture) {
                _ = try CryptoResearchCorpus.decode(data: invalid)
            }
        }
        let original = try fixtureRows()
        var duplicate = original
        duplicate[1]["name"] = duplicate[0]["name"]
        try expectInvalid(duplicate)
        for invalidX in ["00", String(repeating: "g", count: 64), String(repeating: "Ａ", count: 64)] {
            var invalidHex = original
            invalidHex[0]["x"] = invalidX
            try expectInvalid(invalidHex)
        }
        var missingExpectation = original
        missingExpectation[0].removeValue(forKey: "evenY")
        try expectInvalid(missingExpectation)
        var oddY = original
        oddY[0]["evenY"] = String(repeating: "0", count: 63) + "1"
        try expectInvalid(oddY)
        var malformedY = original
        malformedY[0]["evenY"] = "invalid"
        try expectInvalid(malformedY)
    }

    @Test("A previously cancelled caller cannot start the fixed demo")
    func preCancelledCaller() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CryptoResearchDemo.run()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("Caller cancellation reaches detached work and cannot return a report")
    func runningCancellation() async {
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let workerObservedCancellation = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await CryptoResearchDemo.runInBackground {
                started.signal()
                guard proceed.wait(timeout: .now() + 5) == .success else {
                    throw TestFailure.timeout
                }
                workerObservedCancellation.withLock { $0 = Task<Never, Never>.isCancelled }
                try Task.checkCancellation()
                return CryptoResearchReport(results: [])
            }
        }
        let didStart = await Task.detached { Self.waitForSignal(started) }.value
        #expect(didStart)
        task.cancel()
        proceed.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(workerObservedCancellation.withLock { $0 })
    }

    @Test("The evaluator checks cancellation between cases")
    func iterationCancellation() async throws {
        let vector = try generatorVector()
        let evaluations = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            try CryptoResearchRunner.run(vectors: [vector, vector], evaluate: { _ in
                evaluations.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(evaluations.withLock { $0 } == 1)
    }

    // SEC 2's secp256k1 generator, independent of the copied JSON fixture.
    private let generatorY = "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"

    private func generatorVector() throws -> CryptoResearchVector {
        CryptoResearchVector(
            name: "SEC2-generator",
            x: try CryptoResearchHex.decodeCoordinate(
                "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
            ),
            evenY: try CryptoResearchHex.decodeCoordinate(generatorY)
        )
    }

    private func fixtureRows() throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: CryptoResearchCorpus.data()) as? [[String: Any]])
    }

    private func expectInvalid(_ rows: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: rows)
        #expect(throws: CryptoResearchError.invalidFixture) {
            _ = try CryptoResearchCorpus.decode(data: data)
        }
    }

    private static func waitForSignal(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 5) == .success
    }

    private enum TestFailure: Error { case timeout }
}
