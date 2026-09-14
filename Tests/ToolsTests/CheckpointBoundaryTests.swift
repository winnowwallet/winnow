import Testing
import WalletCore
@testable import WinnowDebug

/// A checkpoint refreshed by the generator must sit on a difficulty-period
/// boundary, so every retarget after it is verified exactly (IR-002).
@Suite("Checkpoint boundary")
struct CheckpointBoundaryTests {
    @Test("a mid-period height is refused with the nearest boundary named; a boundary passes")
    func boundary() throws {
        #expect(throws: GenerateError.self) {
            try CheckpointGenerator.requirePeriodBoundary(900_000, params: .mainnet)
        }
        #expect(throws: Never.self) {
            try CheckpointGenerator.requirePeriodBoundary(901_152, params: .mainnet)
        }
        #expect(throws: Never.self) {
            try CheckpointGenerator.requirePeriodBoundary(0, params: .mainnet)
        }
    }
}
