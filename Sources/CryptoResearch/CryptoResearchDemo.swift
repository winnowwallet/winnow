import Foundation
import NativeSecp256k1

/// A fixed public-data demonstration, never a provider of wallet cryptography.
/// No wallet key, transaction, signature, network response or user input is accepted.
public enum CryptoResearchDemo {
    /// Runs the bundled corpus away from the caller's actor. Cancellation is checked
    /// between cases; one field calculation already in progress may finish first.
    public static func run() async throws -> CryptoResearchReport {
        try await runInBackground {
            try Task.checkCancellation()
            let vectors = try CryptoResearchCorpus.load()
            return try CryptoResearchRunner.run(vectors: vectors)
        }
    }

    static func runInBackground(
        operation: @escaping @Sendable () throws -> CryptoResearchReport
    ) async throws -> CryptoResearchReport {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            let report = try await worker.value
            try Task.checkCancellation()
            return report
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Immutable results of comparing public vectors against precomputed references.
/// Passing these cases is not a security audit or a signature verification result.
public struct CryptoResearchReport: Sendable, Equatable {
    public let results: [CryptoResearchCaseResult]
    public let totalCount: Int
    public let matchedCount: Int
    public let mismatchCount: Int
    /// Number of vectors the independent reference marks valid.
    public let validCaseCount: Int
    /// Number of vectors the independent reference marks invalid.
    public let invalidCaseCount: Int
    public let fixtureRevision: String

    init(results: [CryptoResearchCaseResult]) {
        self.results = results
        totalCount = results.count
        matchedCount = results.filter(\.passed).count
        mismatchCount = results.count - matchedCount
        validCaseCount = results.filter(\.expectedValid).count
        invalidCaseCount = results.count - validCaseCount
        fixtureRevision = "2ef204167972efc428486e823fc79b1f1bf0e9e7"
    }
}

public struct CryptoResearchCaseResult: Sendable, Equatable {
    public let name: String
    public let expectedValid: Bool
    public let actualValid: Bool
    public let expectedEvenYHex: String?
    public let actualEvenYHex: String?
    /// True only when both acceptance and the exact even-y coordinate agree.
    public let passed: Bool

    init(vector: CryptoResearchVector, actualEvenY: Data?) {
        name = vector.name
        expectedValid = vector.evenY != nil
        actualValid = actualEvenY != nil
        expectedEvenYHex = vector.evenY.map(CryptoResearchHex.encode)
        actualEvenYHex = actualEvenY.map(CryptoResearchHex.encode)
        passed = vector.evenY == actualEvenY
    }
}

enum CryptoResearchRunner {
    static func run(
        vectors: [CryptoResearchVector],
        evaluate: @Sendable (Data) -> Data? = {
            ExperimentalXOnlyPublicKey(rawRepresentation: $0)?.evenYRepresentation
        }
    ) throws -> CryptoResearchReport {
        var results: [CryptoResearchCaseResult] = []
        results.reserveCapacity(vectors.count)
        for vector in vectors {
            try Task.checkCancellation()
            results.append(CryptoResearchCaseResult(vector: vector, actualEvenY: evaluate(vector.x)))
        }
        try Task.checkCancellation()
        return CryptoResearchReport(results: results)
    }
}
