import Foundation
import UserNotifications
import WalletCore
import XCTest
@testable import WinnowApp

@MainActor final class ChannelProtectionTests: XCTestCase {
    private func preferences() -> UserDefaults { UserDefaults(suiteName: "protection-test.\(UUID())")! }
    func testOnlyCompleteScanClearsWarningAndFailureSurvivesRelaunch() async throws {
        let defaults = preferences(), notifications = TestChannelNotifications()
        let protection = ChannelProtection(defaults: defaults, notifications: notifications)
        let now = Date()
        protection.channelState(network: .mainnet, funded: true, now: now)
        XCTAssertEqual(protection.warning(now: now)?.severity, .waiting)
        protection.scanCompleted(network: .mainnet, now: now)
        XCTAssertNil(protection.warning(now: now))
        protection.channelState(network: .mainnet, funded: true, now: now.addingTimeInterval(10))
        XCTAssertEqual(protection.warning(now: now.addingTimeInterval(3601))?.severity, .overdue,
                       "a peer/channel refresh must not refresh the verified check")
        protection.scanFailed(network: .mainnet)
        let reopened = ChannelProtection(defaults: defaults, notifications: notifications)
        XCTAssertEqual(reopened.warning(now: now)?.severity, .overdue)
        reopened.scanCompleted(network: .mainnet, now: now.addingTimeInterval(20))
        XCTAssertNil(reopened.warning(now: now.addingTimeInterval(20)))
        XCTAssertEqual(reopened.warning(now: now.addingTimeInterval(21621))?.severity, .urgent)
        await protection.flushReminders(); await reopened.flushReminders()
    }
    /// A scan the Bitcoin wallet ran alone, while Lightning could not open,
    /// never counts as a check of funded channels.
    func testAScanLightningDidNotWatchLeavesFundedChannelsUnchecked() async {
        let protection = ChannelProtection(defaults: preferences(), notifications: TestChannelNotifications())
        let now = Date()
        protection.channelState(network: .mainnet, funded: true, now: now)
        protection.scanFinished(network: .mainnet, watched: false, now: now)
        XCTAssertEqual(protection.warning(now: now)?.severity, .overdue)
        protection.scanFinished(network: .mainnet, watched: true, now: now)
        XCTAssertNil(protection.warning(now: now))
        await protection.flushReminders()
    }
    func testNormalSuspensionDoesNotTriggerFailureAlerts() {
        let error = POSIXError(.ECONNRESET)
        XCTAssertFalse(ChannelProtection.isFailedCheck(CancellationError(), cancelled: false))
        XCTAssertFalse(ChannelProtection.isFailedCheck(error, cancelled: true), "closing sockets while suspending is expected")
        XCTAssertTrue(ChannelProtection.isFailedCheck(error, cancelled: false), "an unexpected lost connection must still warn")
    }
    func testReminderConsentAndDeniedPermissionNeverHideInAppWarning() async {
        let notifications = TestChannelNotifications(), protection = ChannelProtection(defaults: preferences(), notifications: notifications)
        protection.channelState(network: .mainnet, funded: true)
        await protection.flushReminders()
        XCTAssertEqual(notifications.authorizationRequests, 0, "no automatic permission prompt")
        XCTAssertTrue(notifications.requests.isEmpty)
        notifications.status = .denied
        await protection.setReminders(true)
        XCTAssertFalse(protection.remindersEnabled)
        XCTAssertNotNil(protection.warning())
        XCTAssertTrue(notifications.requests.isEmpty)
        notifications.status = .authorized
        await protection.setReminders(true)
        XCTAssertTrue(protection.remindersEnabled)
        XCTAssertEqual(notifications.requests.count, 2)
        await protection.setReminders(false)
        XCTAssertTrue(notifications.requests.isEmpty)
        XCTAssertNotNil(protection.warning())
    }
    func testNetworkSwitchKeepsOtherRemindersAndVerifiedCloseCancelsOnlyItsOwn() async throws {
        let defaults = preferences(), notifications = TestChannelNotifications()
        notifications.status = .authorized
        let protection = ChannelProtection(defaults: defaults, notifications: notifications)
        protection.channelState(network: .mainnet, funded: true)
        protection.channelState(network: .signet, funded: true)
        await protection.setReminders(true)
        XCTAssertEqual(notifications.requests.count, 4)
        let original = Set(notifications.requests.keys)
        protection.scanCompleted(network: .signet)
        await protection.flushReminders()
        XCTAssertEqual(notifications.requests.count, 4)
        XCTAssertEqual(Set(notifications.requests.keys.filter { $0.contains(".mainnet.") }),
                       Set(original.filter { $0.contains(".mainnet.") }))
        protection.channelState(network: .signet, funded: false)
        await protection.flushReminders()
        XCTAssertEqual(notifications.requests.count, 2)
        XCTAssertEqual(protection.warning()?.network, .mainnet)
        let restored = ChannelProtection(defaults: defaults, notifications: notifications)
        await restored.refreshPermission()
        XCTAssertEqual(notifications.requests.count, 2)
        XCTAssertEqual(Set(notifications.requests.keys), Set(original.filter { $0.contains(".mainnet.") }))
        restored.channelState(network: .mainnet, funded: false)
        await restored.flushReminders()
        XCTAssertTrue(notifications.requests.isEmpty)
        XCTAssertNil(restored.warning())
    }
    func testDeliveredReminderIsNotRepeatedOnEveryLaunchAndNewScanReschedules() async {
        let defaults = preferences(), notifications = TestChannelNotifications()
        notifications.status = .authorized
        let protection = ChannelProtection(defaults: defaults, notifications: notifications)
        let now = Date()
        protection.channelState(network: .mainnet, funded: true, now: now)
        protection.scanCompleted(network: .mainnet, now: now)
        await protection.setReminders(true)
        XCTAssertEqual(Set(notifications.requests.values.map { $0.date.timeIntervalSince(now) }), Set([3600, 21600]))
        XCTAssertEqual(notifications.added, 2)
        notifications.requests = [:] // iOS delivered them while the app was closed
        let restored = ChannelProtection(defaults: defaults, notifications: notifications)
        await restored.refreshPermission()
        XCTAssertEqual(notifications.added, 2)
        restored.scanCompleted(network: .mainnet, now: now.addingTimeInterval(100))
        await restored.flushReminders()
        XCTAssertEqual(notifications.added, 4)
        XCTAssertEqual(notifications.requests.count, 2)
    }
    func testSchedulingFailureIsVisibleAndCanBeRetried() async {
        let notifications = TestChannelNotifications(), protection = ChannelProtection(defaults: preferences(), notifications: notifications)
        notifications.status = .authorized; notifications.failAdd = true
        protection.channelState(network: .mainnet, funded: true)
        await protection.setReminders(true)
        XCTAssertNotNil(protection.notificationError)
        XCTAssertTrue(notifications.requests.isEmpty)
        notifications.failAdd = false
        await protection.refreshPermission()
        XCTAssertEqual(notifications.requests.count, 2)
        XCTAssertNil(protection.notificationError)
    }
    func testSystemRequestsUseNonRepeatingTriggersAndNoWalletDetails() throws {
        let now = Date()
        for delta: TimeInterval in [-100, 3600] {
            let request = SystemChannelNotifications.request(.init(id: "test", date: now.addingTimeInterval(delta), urgent: true), now: now)
            let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
            XCTAssertFalse(trigger.repeats)
            XCTAssertEqual(trigger.timeInterval, max(1, delta))
            XCTAssertTrue(request.content.body.contains("does not check the chain"))
            XCTAssertTrue(request.content.body.contains("justice transaction"))
            XCTAssertTrue(request.content.userInfo.isEmpty)
            XCTAssertEqual(request.content.badge, nil)
        }
    }
    func testFailedCheckQueuesOneImmediateReminderWithoutRepeatedAlerts() async throws {
        let notifications = TestChannelNotifications(), protection = ChannelProtection(defaults: preferences(), notifications: notifications)
        notifications.status = .authorized
        protection.channelState(network: .mainnet, funded: true)
        protection.scanCompleted(network: .mainnet)
        await protection.setReminders(true)
        protection.scanFailed(network: .mainnet)
        await protection.flushReminders()
        let failed = try XCTUnwrap(notifications.requests.values.first { $0.id.hasSuffix(".failed") })
        XCTAssertLessThan(abs(failed.date.timeIntervalSinceNow), 2)
        XCTAssertEqual(notifications.added, 3)
        protection.scanFailed(network: .mainnet)
        await protection.flushReminders()
        XCTAssertEqual(notifications.added, 3)
        protection.scanCompleted(network: .mainnet)
        await protection.flushReminders()
        XCTAssertEqual(notifications.requests.count, 2)
        XCTAssertFalse(notifications.requests.keys.contains { $0.hasSuffix(".failed") })
    }
}

@MainActor private final class TestChannelNotifications: ChannelNotifications {
    var status = UNAuthorizationStatus.notDetermined
    var authorizationRequests = 0
    var requests: [String: ChannelReminder] = [:]
    var added = 0
    var failAdd = false
    func permission() async -> UNAuthorizationStatus { status }
    func authorize() async throws -> Bool {
        authorizationRequests += 1
        if status == .notDetermined { status = .authorized }
        return status == .authorized
    }
    func pendingIDs() async -> Set<String> { Set(requests.keys) }
    func add(_ reminder: ChannelReminder, now: Date) async throws {
        if failAdd { throw CocoaError(.fileWriteUnknown) }
        requests[reminder.id] = reminder; added += 1
    }
    func remove(ids: [String]) { for id in ids { requests.removeValue(forKey: id) } }
}
