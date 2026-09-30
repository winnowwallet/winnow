import Foundation
import Observation
import UserNotifications
import WalletCore

/// Reminder times are conservative prompts, never a channel's safety deadline.
/// Connectivity alone cannot establish that its commitment outputs were checked.
@Observable @MainActor
final class ChannelProtection {
    struct Record: Codable, Equatable {
        var started: Date
        var checked: Date?
        var failed = false
        var generation = UUID().uuidString
        var anchor: Date { checked ?? started }
    }
    enum Severity: Int { case waiting, overdue, urgent }
    struct Warning {
        let network: BitcoinNetwork
        let record: Record
        let severity: Severity
        var title: String {
            switch severity {
            case .waiting: "Lightning channels need a chain check"
            case .overdue: "Lightning channel check overdue"
            case .urgent: "Check your Lightning channels now"
            }
        }
    }
    static let overdue: TimeInterval = 60 * 60
    static let urgent: TimeInterval = 6 * 60 * 60
    /// Suspending foreground networking is expected when closing the app or
    /// switching networks. Only an actual failed check should trigger an alert.
    static func isFailedCheck(_ error: any Error, cancelled: Bool) -> Bool {
        !cancelled && !(error is CancellationError)
    }
    private(set) var records: [String: Record]
    private(set) var remindersEnabled: Bool
    private(set) var notificationPermission = UNAuthorizationStatus.notDetermined
    private(set) var notificationError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifications: any ChannelNotifications
    @ObservationIgnored private var scheduling: Task<Void, Never>?
    private static let storageKey = "lightning.protection.v1"
    private static let enabledKey = "lightning.protection.reminders"
    private static let queuedKey = "lightning.protection.queued"

    init(defaults: UserDefaults, notifications: any ChannelNotifications = SystemChannelNotifications()) {
        self.defaults = defaults; self.notifications = notifications
        records = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
        remindersEnabled = defaults.bool(forKey: Self.enabledKey)
    }
    func channelState(network: BitcoinNetwork, funded: Bool, now: Date = .now) {
        guard funded != (records[network.rawValue] != nil) else { return }
        if funded, records[network.rawValue] == nil { records[network.rawValue] = Record(started: now) }
        if !funded { records.removeValue(forKey: network.rawValue) }
        persistAndSchedule()
    }
    func scanCompleted(network: BitcoinNetwork, now: Date = .now) {
        guard var record = records[network.rawValue] else { return }
        record.checked = now; record.failed = false; record.generation = UUID().uuidString
        records[network.rawValue] = record; persistAndSchedule()
    }
    func scanFailed(network: BitcoinNetwork) {
        guard var record = records[network.rawValue], !record.failed else { return }
        record.failed = true; records[network.rawValue] = record; persistAndSchedule()
    }
    func warning(now: Date = .now) -> Warning? {
        records.compactMap { name, record -> Warning? in
            guard let network = BitcoinNetwork(rawValue: name) else { return nil }
            let age = now.timeIntervalSince(record.anchor)
            let severity: Severity
            if age >= Self.urgent { severity = .urgent }
            else if age >= Self.overdue || record.failed { severity = .overdue }
            else if record.checked == nil { severity = .waiting }
            else { return nil }
            return Warning(network: network, record: record, severity: severity)
        }.sorted { left, right in
            if left.severity.rawValue != right.severity.rawValue { return left.severity.rawValue > right.severity.rawValue }
            return left.record.anchor < right.record.anchor
        }.first
    }
    func setReminders(_ enabled: Bool) async {
        notificationError = nil
        do {
            if enabled { _ = try await notifications.authorize() }
            notificationPermission = await notifications.permission()
            remindersEnabled = enabled && Self.allowed(notificationPermission)
            defaults.set(remindersEnabled, forKey: Self.enabledKey)
            schedule()
            await scheduling?.value
        } catch { notificationError = "Could not enable reminders. \(error.localizedDescription)" }
    }
    func refreshPermission() async {
        notificationPermission = await notifications.permission()
        schedule(); await scheduling?.value
    }
    private static func allowed(_ permission: UNAuthorizationStatus) -> Bool {
        permission == .authorized || permission == .provisional || permission == .ephemeral
    }
    private func persistAndSchedule() {
        if let bytes = try? JSONEncoder().encode(records) { defaults.set(bytes, forKey: Self.storageKey) }
        schedule()
    }
    private func schedule() {
        let previous = scheduling
        scheduling = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await reconcile(now: .now)
        }
    }
    func flushReminders() async { await scheduling?.value }
    private func reconcile(now: Date) async {
        notificationError = nil
        notificationPermission = await notifications.permission()
        let desired = remindersEnabled && Self.allowed(notificationPermission) ? requests() : []
        let valid = Set(desired.map(\.id))
        let pending = await notifications.pendingIDs()
        let previouslyQueued = Set(defaults.stringArray(forKey: Self.queuedKey) ?? [])
        let obsolete = pending.union(previouslyQueued).filter { $0.hasPrefix(ChannelReminder.prefix) && !valid.contains($0) }
        notifications.remove(ids: Array(obsolete))
        var queued = previouslyQueued.intersection(valid)
        for reminder in desired where !pending.contains(reminder.id) && !queued.contains(reminder.id) {
            do { try await notifications.add(reminder, now: now); queued.insert(reminder.id) }
            catch { notificationError = "Channel reminders could not be scheduled. Open Winnow regularly." }
        }
        defaults.set(Array(queued), forKey: Self.queuedKey)
    }
    private func requests() -> [ChannelReminder] {
        records.flatMap { name, record in
            var reminders = [("overdue", Self.overdue), ("urgent", Self.urgent)].map { level, delay in
                ChannelReminder(id: "\(ChannelReminder.prefix)\(name).\(record.generation).\(level)",
                    date: record.anchor.addingTimeInterval(delay), urgent: level == "urgent")
            }
            if record.failed {
                reminders.append(ChannelReminder(id: "\(ChannelReminder.prefix)\(name).\(record.generation).failed",
                                                 date: .now, urgent: true))
            }
            return reminders
        }
    }
}

struct ChannelReminder: Sendable {
    static let prefix = "winnow.channel-check."
    let id: String
    let date: Date
    let urgent: Bool
}

@MainActor protocol ChannelNotifications {
    func permission() async -> UNAuthorizationStatus
    func authorize() async throws -> Bool
    func pendingIDs() async -> Set<String>
    func add(_ reminder: ChannelReminder, now: Date) async throws
    func remove(ids: [String])
}

@MainActor struct SystemChannelNotifications: ChannelNotifications {
    private var center: UNUserNotificationCenter { .current() }
    func permission() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func authorize() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingIDs() async -> Set<String> { Set(await center.pendingNotificationRequests().map(\.identifier)) }
    func add(_ reminder: ChannelReminder, now: Date) async throws {
        try await center.add(Self.request(reminder, now: now))
    }
    static func request(_ reminder: ChannelReminder, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.urgent ? "Check your Lightning channels now" : "Lightning channel check overdue"
        content.body = "Open Winnow and finish syncing with Bitcoin peers. Offline channels can lose funds if a revoked commitment is not challenged in time. This reminder does not check the chain or broadcast a justice transaction."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.date.timeIntervalSince(now)), repeats: false)
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }
    func remove(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
