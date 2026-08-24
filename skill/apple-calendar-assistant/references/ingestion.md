# Schedule ingestion

Use the bundled parser for deterministic local extraction:

```text
python3 ~/.codex/skills/apple-calendar-assistant/scripts/parse_schedule.py INPUT
```

It supports CSV/TSV, XLSX, ICS, JSON, text, HTML, and text-based PDF. Its JSON output contains `records`, `warnings`, `requiresModel`, and `requiresBrowser`.

- CSV/TSV/XLSX/JSON: map recognizable columns to drafts. Preserve the row reference in `sourceRef`; ask once for unmapped column meaning when needed.
- ICS: preserve explicit dates, timezones, recurrence, location, description, and alerts. Preview before importing.
- PDF: use locally extracted page text when present. If `requiresModel` is true, use PDF/image understanding and preview all derived items.
- Images: use image understanding; the parser only records file metadata.
- URL: use the in-app browser, including its existing signed-in session when available. Never ask for or store school credentials. If access fails, request a file or screenshot.
- HTML saved locally: parse visible text locally, then use the model only when the layout-to-column mapping is ambiguous.

Never retain an uploaded source merely for auditing. The bridge stores normalized before/after fields and a short `sourceRef`, not the raw source.
