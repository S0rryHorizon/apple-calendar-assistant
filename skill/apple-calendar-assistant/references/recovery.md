# Recovery

- `diagnostics`: protocol/build version, manifest hashes and installation drift; no permission prompt or database migration.
- `operation.status` with the original `batchId`: durable result. A pending/executing write is `unknown`, never safe to retry blindly.
- `operation.reconcile` with the original ID: compares recorded after-images with current Apple items. Only a complete match becomes `committed`; it never creates or edits Apple items. Missing audit records or unmatched items remain `unknown` with verified counts.
- Repeating a completed request with identical content returns the original result. Reusing its ID for different content is rejected. Query status after an ambiguous response; do not change IDs to bypass the guard.
- `batch.rollback`, with confirmed authorization, restores recorded items in reverse order. Changed targets stop rollback. Each completed step is recorded; an interrupted in-flight step is left for inspection. No rollback is advertised as atomic across EventKit and SQLite.
- Native helper failures stop reminder writes. A system upgrade may require code adaptation; reinstalling/recompiling alone is not guaranteed to fix private APIs.
- Writes with no trustworthy evidence remain stopped. Report the batch, verified saved items and unresolved steps; preserve the journal and SQLite audit. Do not delete them to unblock work.
