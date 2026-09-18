# CalendarBridge protocol 2

One JSON request on stdin, one JSON response on stdout. Errors return `ok:false`; a process exit code alone is not a success receipt.

Actions: `diagnostics`, `setup`, `status`, `event.list/create/update/patch/delete`, `reminder.list/create/update/patch/delete/complete`, `batch.preview/commit/rollback`, `operation.status/reconcile`.

## Creates and batches

```json
{"action":"event.create","dryRun":true,"batchId":"stable-uuid","item":{"kind":"event","title":"Library","start":"2030-09-03T15:00:00+08:00"}}
```

Retain the returned batch ID. Send the identical request with `dryRun` omitted for creation after the appropriate authorization. Batch work uses `batch.preview` with `items`, then `batch.commit` with the **same input items**, returned `batchId`, and `confirmed:true`. Resolved batch defaults are frozen at preview; do not rebuild them from item summaries. New conflicts or target-container changes require a fresh preview and decision.

Every write requires a stable `batchId`; legacy requests without it return an upgrade error. Each ID is permanently bound to one write payload. Repeating a completed identical request returns its result, without executing again. `requestId` is optional correlation metadata, not an idempotency key.

Draft fields: `kind`, `title`, `start`, `end`, `due`, `allDay`, `timezone`, `location`, `notes`, `url`, `alerts`, `earlyReminder`, `recurrence`, `sourceRef`. Events need `start`; reminders need `due`. Use ISO 8601 with an offset. `alerts` contains objects with exactly one of `at` or `minutesBefore`; `[]` clears alerts.

Native `earlyReminder` uses `unit` 0/1/2/3/4 for minutes/hours/days/weeks/months and a negative `count` for before, e.g. `{"unit":3,"count":-1}`. It is distinct from generic EventKit alarms. Creation and changes require compatible helper probe and actual readback.

Creation recurrence: `{"frequency":"weekly","interval":1,"daysOfWeek":["MO","WE"],"endDate":"2030-12-01T23:59:59+08:00"}`. Frequencies: daily/weekly/monthly; specify only one of endDate/count. Mutations of recurring or detached existing items are currently rejected because complete series recovery cannot yet be guaranteed; scope=this/future does not bypass this guard.

## Partial updates

```json
{"action":"event.patch","dryRun":true,"batchId":"patch-uuid","selector":{"id":"EVENTKIT-ID"},"patch":{"start":"2030-09-03T16:00:00+08:00"}}
```

After confirmation, repeat with `confirmed:true` and omit `dryRun`. Omission preserves existing fields. Moving an event's start without supplying an end preserves duration. `clear:["notes","location"]` explicitly clears optional fields. Supported clear names: location, notes, url, alerts, earlyReminder, recurrence. Setting and clearing the same field is invalid.

Old `event.update` / `reminder.update` still replace the full item; they now require a matching dry-run preview and batch ID. Prefer patch.

Delete/complete also require `dryRun:true` first, stable `selector.id` and `batchId`, then identical request with `confirmed:true`. A change to the original item invalidates the preview.

## Queries and results

List requests accept `range:{"start":"...","end":"..."}`. Mutations should select stable IDs. Responses include `status`, `batchId`, `items`, `conflicts`, `duplicates`, `details` when applicable. Items contain actual saved location and alerts.

- `preview` / `needs_confirmation`: no Apple item written.
- `committed`: durable write receipt; report saved items and batch ID.
- `rolled_back`: completed recorded rollback.
- `unknown`: outcome requires inspection, even when some writes may have succeeded.
- `error`: request/preflight failure; do not claim success.

Read [recovery.md](recovery.md) for outcome reconciliation and rollback. A `batch.commit` or `batch.rollback` with dryRun is rejected; use batch.preview for imports.
