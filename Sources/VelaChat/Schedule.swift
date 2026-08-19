import Foundation
import EventKit

/// Read-only calendar + reminders access for the `get_schedule` tool.
/// The system permission prompt (macOS 14+ full-access API, verified
/// against the SDK headers) is the gate; denial returns an honest error
/// the model can relay.
@MainActor
enum ScheduleReader {
    private static let store = EKEventStore()

    static func schedule(days: Int) async -> String {
        let horizon = max(1, min(days, 7))
        let eventsGranted = await requestEvents()
        let remindersGranted = await requestReminders()
        guard eventsGranted || remindersGranted else {
            return "Error: the user has not granted calendar or reminders access."
        }
        var sections: [String] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        if eventsGranted {
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: horizon, to: start) ?? start
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate).prefix(60)
            if events.isEmpty {
                sections.append("No calendar events in the next \(horizon) day(s).")
            } else {
                let lines = events.map { event -> String in
                    let time = event.isAllDay
                        ? "all day \(DateFormatter.localizedString(from: event.startDate, dateStyle: .short, timeStyle: .none))"
                        : "\(formatter.string(from: event.startDate)) – \(DateFormatter.localizedString(from: event.endDate, dateStyle: .none, timeStyle: .short))"
                    return "- \(event.title ?? "Untitled") (\(time), \(event.calendar.title))"
                }
                sections.append("Calendar events (next \(horizon) day(s)):\n" + lines.joined(separator: "\n"))
            }
        }
        if remindersGranted {
            let reminders = await incompleteReminders()
            if !reminders.isEmpty {
                let lines = reminders.prefix(40).map { reminder -> String in
                    let due = reminder.dueDateComponents.flatMap(Calendar.current.date(from:))
                        .map { " (due \(formatter.string(from: $0)))" } ?? ""
                    return "- \(reminder.title ?? "Untitled")\(due)"
                }
                sections.append("Open reminders:\n" + lines.joined(separator: "\n"))
            }
        }
        let text = sections.joined(separator: "\n\n")
        return text.count > 6_000 ? String(text.prefix(6_000)) + "\n[Truncated.]" : text
    }

    private static func requestEvents() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .denied, .restricted, .writeOnly: return false
        default: break
        }
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func requestReminders() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .denied, .restricted, .writeOnly: return false
        default: break
        }
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToReminders { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func incompleteReminders() async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }
}
