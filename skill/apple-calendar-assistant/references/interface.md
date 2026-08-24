# Bridge interface

The bridge reads one JSON object from stdin and writes one JSON response to stdout.

```text
~/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge
```

## Requests

Supported actions:

- `setup`, `status`
- `event.list`, `event.create`, `event.update`, `event.delete`
- `reminder.list`, `reminder.create`, `reminder.update`, `reminder.delete`, `reminder.complete`
- `batch.preview`, `batch.commit`, `batch.rollback`

Shared request fields are `requestId`, `confirmed`, `dryRun`, `item`, `items`, `selector`, `range`, `batchId`, and `scope`. Use `scope: "this"` for one recurring occurrence and `scope: "future"` for that occurrence plus future occurrences.

An event draft:

```json
{
  "kind": "event",
  "title": "数据库课程",
  "start": "2026-09-03T09:00:00+08:00",
  "end": "2026-09-03T10:30:00+08:00",
  "allDay": false,
  "timezone": "Asia/Singapore",
  "location": "Room 201",
  "notes": "Chapter 3",
  "alerts": [{"minutesBefore": 60}],
  "sourceRef": "semester-1.xlsx#row-8"
}
```

A reminder draft uses `due` instead of `start`/`end`. Omit `alerts` for the personal default, provide a complete list to replace it, or use `[]` to remove all alerts. Each alert has exactly one of `at` or `minutesBefore`.

For a reminder with one relative alert, the bridge also accepts Apple's native
Early Reminder field. `unit` is `0` minutes, `1` hours, `2` days, `3` weeks, or
`4` months; use a negative `count` for an alert before the due date. For
example, one week before a 5 September deadline is:

```json
{
  "kind": "reminder",
  "title": "课程项目截止",
  "due": "2026-09-05T23:59:00+08:00",
  "earlyReminder": {"unit": 3, "count": -1}
}
```

This is separate from EventKit's generic alarm and appears on iPhone as
“提前提醒”.

Recurrence is optional:

```json
{"frequency":"weekly","interval":1,"daysOfWeek":["MO","WE"],"endDate":"2026-12-01T23:59:59+08:00"}
```

Frequency is `daily`, `weekly`, or `monthly`; weekday values are `SU`, `MO`, `TU`, `WE`, `TH`, `FR`, `SA`. Specify only one of `endDate` and `count`.

## Examples

Preview a single creation:

```json
{
  "action": "event.create",
  "dryRun": true,
  "item": {
    "kind": "event",
    "title": "图书馆",
    "start": "2026-09-03T15:00:00+08:00"
  }
}
```

Update by stable identifier after confirmation:

```json
{
  "action": "event.update",
  "confirmed": true,
  "selector": {"id": "EVENTKIT-ID"},
  "item": {
    "kind": "event",
    "title": "图书馆",
    "start": "2026-09-03T16:00:00+08:00",
    "alerts": [{"minutesBefore": 30}]
  }
}
```

Batch work is two-phase: send `items` to `batch.preview`, retain its `batchId`, then send the same normalized `items`, `batchId`, and `confirmed: true` to `batch.commit`. Roll back with `{"action":"batch.rollback","batchId":"...","confirmed":true}`.

## Response handling

- `preview`: no conflict or duplicate was found; nothing was written.
- `needs_confirmation`: show `conflicts` and `duplicates`; nothing was written.
- `committed`: report `items` and retain `batchId`.
- `rolled_back`: report restored or removed items.
- `error`: stop. Do not claim success or silently retry.

`items`, `conflicts`, and `duplicates` include `location` when the Calendar or
Reminder item has one. This is the location read back from EventKit after a
write, not just the requested draft value.
