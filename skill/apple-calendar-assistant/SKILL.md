---
name: apple-calendar-assistant
description: Manage Apple Calendar events and Reminders from natural-language requests, schedules, screenshots, files, or webpages. Use when the user wants to add, inspect, change, delete, complete, import, or roll back calendar items or reminders on this Mac. Do not use for merely discussing calendar-app design.
---

# Apple Calendar Assistant

Use Apple Calendar for fixed-time events and Reminders for tasks without a fixed time block. Write through `~/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge`; never automate the Calendar UI when the bridge is available.

## Workflow

1. Parse the request into absolute dates in `Asia/Singapore`. If there is no date, ask for one. Events without an end last one hour.
2. For files or webpages, read [ingestion.md](references/ingestion.md). School schedules that enumerate dates become independent events, not inferred weekly recurrences.
3. Before calling the bridge, read [interface.md](references/interface.md) and build the smallest valid JSON request.
4. Use `dryRun: true` for uncertain input. A clear single create may commit after a clean preview; batch imports, ambiguity, conflicts, duplicates, updates, deletes, completions, and rollbacks require explicit user confirmation.
5. Report the effective saved fields, alerts, and `batchId`. If the bridge reports fewer alerts than requested, disclose the provider limit.

## Personal rules

- Omitted alerts mean the previous calendar day at 22:00. For a reminder, the bridge stores a single alert as Apple's native `earlyReminder` field (so iPhone keeps the due date visible); `earlyReminder` uses `unit` 0/1/2/3/4 for minutes/hours/days/weeks/months and a negative `count` for “before”. Explicit alerts replace the default; words such as “再加” or “另外” mean include both. An empty alert array removes all alerts and clears the native Early Reminder.
- If the default alert is already past, the bridge uses one hour before, then fifteen minutes before, then immediate notification according to remaining time.
- Warn and ask before accepting an overlap. For duplicates, offer skip, overwrite, or create anyway.
- Use the current default Calendar and Reminders containers only after `status` confirms both are iCloud-backed.
- Common daily, weekly, and monthly recurrences are supported. For a recurring event mutation, confirm whether `scope` is `this` or `future`.
- Do not retry a failed mutation automatically. Preserve the returned batch identifier for rollback.

If access is `not_determined`, explain that `setup` opens macOS permission prompts and obtain authorization before calling it. If access is denied or the default container is not iCloud, stop and provide the bridge error rather than falling back to UI automation.
