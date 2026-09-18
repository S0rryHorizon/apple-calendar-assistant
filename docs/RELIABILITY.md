# Recovery and controlled validation

The recovery path reads the existing SQLite audit and operation journal. It does not
create a second recovery log. `batch.rollback` and `operation.reconcile` pass through
`EventKitService.handle`; `MutationCoordinator` records a stable operation ID before a
write and keeps an uncertain outcome from being executed again under that ID.

Run the synthetic checks from a checkout on macOS:

```sh
swift build
swift run CalendarBridgeSelfTest
swift run CalendarBridgeReliabilityTests
swift run CalendarBridgeServiceTests
swift run CalendarBridgeServiceTests --demo
python3 -m venv .venv
.venv/bin/python -m pip install -r Tests/requirements.txt
.venv/bin/python -m unittest Tests/parser_test.py Tests/installer_test.py
```

`CalendarBridgeServiceTests --demo` is the short controlled walkthrough: it prints
the successful restoration of a completed synthetic reminder to its original list,
then an uncertain lookup that leaves the synthetic audit intact. The full runner creates invented
events and reminders in a fake recovery backend, drives the actual service handler,
and uses temporary SQLite audit files and a journal. It checks found versus proven
absent versus failed lookup, read-only reconciliation of a recorded delete, original
container restoration, reminder completion, legacy and invalid snapshots, and a
failure after a synthetic write. Query regressions cover a rollback failure after
a side effect, interrupted rollback, successful rollback, and an original operation
without rollback. The service constructs no `EKEventStore` in these
scenarios, so the runner does not open a real calendar, request TCC permission, or
invoke the private ReminderKit helper. The installer tests use temporary directories
and do not install the app or Skill.

New audit snapshots record the original calendar or reminder-list identifier. Old
snapshots still decode, but a missing original container cannot authorize automatic
restoration. A deleted item is recreated only in its recorded container after access,
entity type and writability checks. The existing `ItemSummary.completed` value is
used to restore a reminder's completion state; if it is unknown, recovery stops.
Recorded item identity is checked by identifier. A title and nearby date never
establish that a different item is the original. A missing item is treated as absent
only after the original container and access checks, plus an external-identifier
lookup that finds no surviving match. Lookup errors and ambiguous matches remain
unknown.

Both `operation.status` and `operation.reconcile` use the original `batchId`.
Once rollback has been recorded, both queries return its receipt with
`details.operation` set to `batch.rollback`, before considering the original write.
An interrupted or failed rollback remains `unknown`; a completed rollback returns
`rolled_back`. Queries preserve the audit and both operation records, never retry
rollback, and do not resolve an uncertain rollback automatically. Without a rollback,
an already committed receipt remains a historical result; reconciliation checks
current items only for an unresolved original write.

An `unknown` result is a deliberate stop. A calendar write can succeed and its audit
write or readback can then fail. Repeating the same operation ID does not write
again; `operation.reconcile` only inspects the recorded audit and current item when
it can, and otherwise keeps the intent unresolved. A new ID could duplicate an item,
so the protocol does not claim exactly-once delivery. Synthetic checks do not prove
behavior on every macOS version, iCloud account, private ReminderKit version, or
interrupted live synchronization. Those paths require separate user-authorized
validation with real EventKit access.
