---
name: apple-calendar-assistant
description: Manage Apple Calendar events and Reminders from natural-language requests, schedules, screenshots, files, or webpages on this Mac. Use for calendar and reminder operations, not calendar-app design.
---

# Apple Calendar Assistant

Resolve `$CALENDAR_BRIDGE_PATH`, otherwise `$HOME/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge`. Use the bridge rather than Calendar UI automation.

Read [interface.md](references/interface.md) before operations. For file/web imports also read [ingestion.md](references/ingestion.md). Personal defaults and configuration are in [preferences.md](references/preferences.md).

- Fixed-time commitments become events; tasks/deadlines become reminders. Ask for missing dates. Enumerated school dates become independent events, not inferred recurrences.
- Preview every write and retain its `batchId` and exact request. A clearly requested single creation may proceed after a clean preview. Batch imports, ambiguity, conflicts, duplicates, updates, deletes, completions and rollbacks need explicit authorization for the displayed content. Existing authorization for identical content remains valid; changed content/conflicts need a new preview and decision.
- Use `event.patch` / `reminder.patch` for partial changes. Omitted fields remain unchanged; explicit `clear` removes fields. Do not reconstruct a full item merely to change its time.
- Commit with the same `batchId`. Report saved fields, alert limits, and batch ID. `unknown` is not success: read [recovery.md](references/recovery.md), query the original operation, and never create a replacement under a new ID.
- Native Early Reminder must pass the bridge's probe and readback. Do not silently substitute ordinary alarms. Unsupported recurring mutations stop before writing.
- `diagnostics` checks installation without requesting Apple permissions. If permissions need initialization, explain `setup` and obtain authorization for its system prompts. Denied access or a non-iCloud target stops the operation.
