import Foundation
import VelaCore
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

    /// Creates a reminder or a calendar event. Write access uses the same
    /// full-access grant the read path already requests; a denial is
    /// reported honestly rather than silently dropping the item.
    static func create(
        kind: String,
        title: String,
        startISO: String?,
        durationMinutes: Int?,
        notes: String?
    ) async -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return "Error: a title is required." }
        let date = startISO.flatMap { parseDate($0) }

        if kind == "event" {
            guard await requestEvents() else {
                return "Error: the user has not granted calendar access."
            }
            guard let date else {
                return "Error: an event needs a start time (ISO 8601, e.g. 2026-08-20T15:00:00)."
            }
            let event = EKEvent(eventStore: store)
            event.title = trimmedTitle
            event.startDate = date
            event.endDate = date.addingTimeInterval(TimeInterval(max(5, durationMinutes ?? 60) * 60))
            event.notes = notes
            event.calendar = store.defaultCalendarForNewEvents
            guard event.calendar != nil else {
                return "Error: no default calendar is available to write to."
            }
            do {
                try store.save(event, span: .thisEvent, commit: true)
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return "Created the event “\(trimmedTitle)” on \(formatter.string(from: date)) in \(event.calendar.title)."
            } catch {
                return "Error creating the event: \(error.localizedDescription)"
            }
        }

        guard await requestReminders() else {
            return "Error: the user has not granted reminders access."
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmedTitle
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        guard reminder.calendar != nil else {
            return "Error: no default reminders list is available to write to."
        }
        if let date {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        do {
            try store.save(reminder, commit: true)
            if let date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return "Created the reminder “\(trimmedTitle)”, due \(formatter.string(from: date))."
            }
            return "Created the reminder “\(trimmedTitle)” (no due date)."
        } catch {
            return "Error creating the reminder: \(error.localizedDescription)"
        }
    }

    /// Accepts full ISO 8601 with or without a timezone, since models
    /// write both.
    private static func parseDate(_ raw: String) -> Date? {
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
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
