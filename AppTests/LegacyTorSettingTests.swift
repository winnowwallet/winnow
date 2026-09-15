@testable import WinnowApp
import XCTest

/// 0.6 through 0.7.0 stored an opt-in Tor route under `torEnabled`. 0.7.1
/// removed the route: an installation that had it on is told once, and the
/// key is cleared so the notice never repeats.
@MainActor
final class LegacyTorSettingTests: XCTestCase {
    func testAnInstallationThatHadTorOnIsToldOnceAndTheKeyIsCleared() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppModel.DefaultsKey.legacyTorEnabled)
        let first = makeModel(defaults: defaults)
        XCTAssertTrue(first.torRemovedNotice)
        XCTAssertNil(defaults.object(forKey: AppModel.DefaultsKey.legacyTorEnabled))
        let second = makeModel(defaults: defaults)
        XCTAssertFalse(second.torRemovedNotice, "the notice shows on one launch only")
    }

    func testAnInstallationWithoutTorSeesNoNotice() {
        for stored in [nil, false] as [Bool?] {
            let defaults = makeDefaults()
            if let stored { defaults.set(stored, forKey: AppModel.DefaultsKey.legacyTorEnabled) }
            XCTAssertFalse(makeModel(defaults: defaults).torRemovedNotice)
            XCTAssertNil(defaults.object(forKey: AppModel.DefaultsKey.legacyTorEnabled))
        }
    }
}
