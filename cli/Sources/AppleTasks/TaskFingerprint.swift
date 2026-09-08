import CryptoKit
import EventKit
import Foundation

/// Content fingerprint of a reminder, used by the dispatcher's completion
/// guard (review P3): Phase C stores it right after our own write-back, and
/// Phase A re-dispatches only when the current fingerprint differs — i.e.
/// the recurrence rolled or a human edited the task. Built from content
/// only (title incl. tags, notes, due, URL, priority), never from
/// `lastModifiedDate`, so iCloud sync churn cannot make a task look changed.
enum TaskFingerprint {
    static func of(title: String?, notes: String?, due: DateComponents?, url: String?, priority: Int) -> String {
        of(title: title, notes: notes, dueText: Dates.formatDue(due), url: url, priority: priority)
    }

    /// Plain-value form (testable without EventKit). `dueText` is whatever
    /// `Dates.formatDue` renders; nil when undated.
    static func of(title: String?, notes: String?, dueText: String?, url: String?, priority: Int) -> String {
        // Field separator that cannot occur in the inputs, so shifting text
        // between fields changes the hash.
        let parts = [title ?? "", notes ?? "", dueText ?? "", url ?? "", String(priority)]
        let joined = parts.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func of(_ reminder: EKReminder) -> String {
        of(title: reminder.title, notes: reminder.notes, due: reminder.dueDateComponents,
           url: reminder.url?.absoluteString, priority: reminder.priority)
    }
}
