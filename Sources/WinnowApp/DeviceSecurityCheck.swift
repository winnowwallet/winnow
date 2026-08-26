import Foundation
import Security
import UIKit
import WalletCore

/// The release gate's on-device question, instrumented: does iOS refuse to
/// hand this app the wallet key while the device is locked?
///
/// `KeychainStore` stores the secret as `WhenUnlockedThisDeviceOnly`, and
/// `AppTests/KeychainAttributeTests` shows the Keychain records that request.
/// What no simulator can show is the platform honouring it — the simulator's
/// Keychain is file-backed, with no data protection to enforce. This check
/// runs where the enforcement lives: start it, lock the phone, and for the
/// next twenty seconds the app samples a read of its own key from the
/// background, recording only the OSStatus of each attempt and whether
/// protected data was available at that moment. `errSecInteractionNotAllowed`
/// (−25308) while locked is the platform keeping its contract. The secret
/// itself never reaches the UI, the journal, or this type.
@MainActor
@Observable
final class DeviceSecurityCheck {
    struct Sample: Codable, Equatable {
        let secondsAfterStart: Double
        /// `UIApplication.isProtectedDataAvailable` at the moment of the
        /// read — false means the device was actually locked, not merely
        /// off-screen with the sample racing the lock animation.
        let protectedDataAvailable: Bool
        let status: OSStatus
    }

    struct Result: Codable, Equatable {
        let startedAt: Date
        let samples: [Sample]
    }

    enum Verdict: Equatable {
        case enforced
        case notEnforced
        case deviceNeverLocked
        case unexpected(OSStatus)
    }

    /// First touched from the app's init so the reading means "since launch",
    /// not "since the user first opened Settings".
    static let launchedAt = Date()

    private(set) var running = false
    /// The configured protection class, read back from the Keychain in the
    /// foreground — nil until the control has run.
    private(set) var accessible: String?
    private(set) var foregroundStatus: OSStatus?
    private(set) var lastResult: Result?

    private var samples: [Sample] = []
    private var startedAt = Date()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private static let defaultsKey = "deviceSecurityCheck.lastResult"

    init() {
        if let data = Self.defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Result.self, from: data) {
            lastResult = stored
        }
    }

    private static var defaults: UserDefaults {
        E2EMode.current?.defaults ?? .standard
    }

    /// The pure half, split out so the rules are testable without a device:
    /// only samples taken while protected data was unavailable count, because
    /// an unlocked read legitimately succeeds.
    nonisolated static func verdict(for samples: [Sample]) -> Verdict {
        let locked = samples.filter { !$0.protectedDataAvailable }
        guard !locked.isEmpty else { return .deviceNeverLocked }
        if locked.allSatisfy({ $0.status == errSecInteractionNotAllowed }) { return .enforced }
        if locked.contains(where: { $0.status == errSecSuccess }) { return .notEnforced }
        return .unexpected(locked.map(\.status).first { $0 != errSecInteractionNotAllowed } ?? 0)
    }

    var verdict: Verdict? {
        lastResult.map { Self.verdict(for: $0.samples) }
    }

    /// Foreground control: the configured class, and proof the item is
    /// readable while unlocked — without it, "refused while locked" could
    /// also mean "refused always".
    func runForegroundControl(store: KeychainStore, walletID: String) {
        let attribute = store.protectionAttribute(walletID: walletID)
        accessible = attribute.accessible
        foregroundStatus = store.readStatus(walletID: walletID)
    }

    /// Arms the locked-device probe. The user locks the phone immediately
    /// after tapping; samples run on the main queue inside a background task
    /// so the ~30-second grace window covers the 20-second schedule. Each
    /// sample persists as it lands, so evidence survives an early suspension.
    func startLockedProbe(store: KeychainStore, walletID: String) {
        guard !running else { return }
        running = true
        samples = []
        startedAt = Date()
        lastResult = nil
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "device-security-check") {
            Task { @MainActor [weak self] in self?.finish() }
        }
        let schedule: [Double] = [5, 10, 15, 20]
        for delay in schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.running else { return }
                self.samples.append(Sample(
                    secondsAfterStart: delay,
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                    status: store.readStatus(walletID: walletID)))
                self.persist()
                if delay == schedule.last { self.finish() }
            }
        }
    }

    private func persist() {
        let result = Result(startedAt: startedAt, samples: samples)
        lastResult = result
        if let data = try? JSONEncoder().encode(result) {
            Self.defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private func finish() {
        guard running else { return }
        running = false
        persist()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// Resident memory of this process, for the soak reading.
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }
}
