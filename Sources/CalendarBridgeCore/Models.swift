import Foundation

public enum BridgeError: Error, CustomStringConvertible, Sendable {
  case invalidRequest(String)
  case permissionDenied(String)
  case iCloudRequired(String)
  case notFound(String)
  case confirmationRequired(String)
  case storage(String)
  case eventKit(String)

  public var description: String {
    switch self {
    case .invalidRequest(let message): "invalid_request: \(message)"
    case .permissionDenied(let message): "permission_denied: \(message)"
    case .iCloudRequired(let message): "icloud_required: \(message)"
    case .notFound(let message): "not_found: \(message)"
    case .confirmationRequired(let message): "confirmation_required: \(message)"
    case .storage(let message): "storage_error: \(message)"
    case .eventKit(let message): "eventkit_error: \(message)"
    }
  }
}

public enum ItemKind: String, Codable, Sendable {
  case event
  case reminder
}

public struct AlertSpec: Codable, Equatable, Sendable {
  public var at: String?
  public var minutesBefore: Int?

  public init(at: String? = nil, minutesBefore: Int? = nil) {
    self.at = at
    self.minutesBefore = minutesBefore
  }
}

/// Reminders' native Early Reminder field.  `unit` follows ReminderKit's
/// stable-on-this-system mapping: 0 minutes, 1 hours, 2 days, 3 weeks,
/// 4 months.  `count` is negative for an alert before the due date.
public struct EarlyReminderSpec: Codable, Equatable, Sendable {
  public var unit: Int
  public var count: Int

  public init(unit: Int, count: Int) {
    self.unit = unit
    self.count = count
  }
}

public struct RecurrenceSpec: Codable, Equatable, Sendable {
  public var frequency: String
  public var interval: Int?
  public var daysOfWeek: [String]?
  public var endDate: String?
  public var count: Int?

  public init(
    frequency: String,
    interval: Int? = nil,
    daysOfWeek: [String]? = nil,
    endDate: String? = nil,
    count: Int? = nil
  ) {
    self.frequency = frequency
    self.interval = interval
    self.daysOfWeek = daysOfWeek
    self.endDate = endDate
    self.count = count
  }
}

public struct ItemDraft: Codable, Equatable, Sendable {
  public var kind: ItemKind
  public var title: String
  public var start: String?
  public var end: String?
  public var due: String?
  public var allDay: Bool?
  public var timezone: String?
  public var location: String?
  public var notes: String?
  public var url: String?
  public var alerts: [AlertSpec]?
  public var earlyReminder: EarlyReminderSpec?
  public var recurrence: RecurrenceSpec?
  public var sourceRef: String?

  public init(
    kind: ItemKind,
    title: String,
    start: String? = nil,
    end: String? = nil,
    due: String? = nil,
    allDay: Bool? = nil,
    timezone: String? = nil,
    location: String? = nil,
    notes: String? = nil,
    url: String? = nil,
    alerts: [AlertSpec]? = nil,
    earlyReminder: EarlyReminderSpec? = nil,
    recurrence: RecurrenceSpec? = nil,
    sourceRef: String? = nil
  ) {
    self.kind = kind
    self.title = title
    self.start = start
    self.end = end
    self.due = due
    self.allDay = allDay
    self.timezone = timezone
    self.location = location
    self.notes = notes
    self.url = url
    self.alerts = alerts
    self.earlyReminder = earlyReminder
    self.recurrence = recurrence
    self.sourceRef = sourceRef
  }
}

public struct ItemSelector: Codable, Equatable, Sendable {
  public var id: String?
  public var title: String?
  public var near: String?

  public init(id: String? = nil, title: String? = nil, near: String? = nil) {
    self.id = id
    self.title = title
    self.near = near
  }
}

public struct DateRange: Codable, Equatable, Sendable {
  public var start: String
  public var end: String

  public init(start: String, end: String) {
    self.start = start
    self.end = end
  }
}

public struct BridgeRequest: Codable, Sendable {
  public var action: String
  public var requestId: String?
  public var confirmed: Bool?
  public var dryRun: Bool?
  public var item: ItemDraft?
  public var items: [ItemDraft]?
  public var selector: ItemSelector?
  public var range: DateRange?
  public var batchId: String?
  public var scope: String?

  public init(
    action: String,
    requestId: String? = nil,
    confirmed: Bool? = nil,
    dryRun: Bool? = nil,
    item: ItemDraft? = nil,
    items: [ItemDraft]? = nil,
    selector: ItemSelector? = nil,
    range: DateRange? = nil,
    batchId: String? = nil,
    scope: String? = nil
  ) {
    self.action = action
    self.requestId = requestId
    self.confirmed = confirmed
    self.dryRun = dryRun
    self.item = item
    self.items = items
    self.selector = selector
    self.range = range
    self.batchId = batchId
    self.scope = scope
  }
}

public struct ItemSummary: Codable, Equatable, Sendable {
  public var id: String
  public var externalId: String?
  public var kind: ItemKind
  public var title: String
  public var start: String?
  public var end: String?
  public var due: String?
  public var allDay: Bool
  public var timezone: String?
  public var location: String?
  public var alerts: [AlertSpec]
  public var earlyReminder: EarlyReminderSpec?
  public var completed: Bool?

  public init(
    id: String,
    externalId: String? = nil,
    kind: ItemKind,
    title: String,
    start: String? = nil,
    end: String? = nil,
    due: String? = nil,
    allDay: Bool = false,
    timezone: String? = nil,
    location: String? = nil,
    alerts: [AlertSpec] = [],
    earlyReminder: EarlyReminderSpec? = nil,
    completed: Bool? = nil
  ) {
    self.id = id
    self.externalId = externalId
    self.kind = kind
    self.title = title
    self.start = start
    self.end = end
    self.due = due
    self.allDay = allDay
    self.timezone = timezone
    self.location = location
    self.alerts = alerts
    self.earlyReminder = earlyReminder
    self.completed = completed
  }
}

public struct BridgeResponse: Codable, Sendable {
  public var ok: Bool
  public var status: String
  public var requestId: String?
  public var message: String?
  public var batchId: String?
  public var items: [ItemSummary]?
  public var conflicts: [ItemSummary]?
  public var duplicates: [ItemSummary]?
  public var details: [String: String]?

  public init(
    ok: Bool,
    status: String,
    requestId: String? = nil,
    message: String? = nil,
    batchId: String? = nil,
    items: [ItemSummary]? = nil,
    conflicts: [ItemSummary]? = nil,
    duplicates: [ItemSummary]? = nil,
    details: [String: String]? = nil
  ) {
    self.ok = ok
    self.status = status
    self.requestId = requestId
    self.message = message
    self.batchId = batchId
    self.items = items
    self.conflicts = conflicts
    self.duplicates = duplicates
    self.details = details
  }
}

public struct ItemSnapshot: Codable, Equatable, Sendable {
  public var summary: ItemSummary
  public var location: String?
  public var notes: String?
  public var url: String?
  public var recurrence: RecurrenceSpec?
  public var sourceRef: String?

  public init(
    summary: ItemSummary,
    location: String? = nil,
    notes: String? = nil,
    url: String? = nil,
    recurrence: RecurrenceSpec? = nil,
    sourceRef: String? = nil
  ) {
    self.summary = summary
    self.location = location
    self.notes = notes
    self.url = url
    self.recurrence = recurrence
    self.sourceRef = sourceRef
  }
}
