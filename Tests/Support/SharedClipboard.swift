import Foundation

/// Verifies native Share completion against the actual clipboard within one budget.
public enum SharedClipboard {
    public static func wait(expected: String, timeout: TimeInterval,
                            read: (TimeInterval) throws -> String,
                            isShareDismissed: () -> Bool,
                            now: () -> Date = Date.init,
                            pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { return false }
            let text = try read(remaining)
            if text == expected && isShareDismissed(),
               deadline.timeIntervalSince(now()) > 0 { return true }
            pause(min(0.2, max(0, deadline.timeIntervalSince(now()))))
        }
    }
}
