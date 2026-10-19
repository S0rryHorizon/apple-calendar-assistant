# Personal defaults

Configuration: `$CALENDAR_BRIDGE_CONFIG`, otherwise `~/Library/Application Support/CalendarBridge/config.json`. Missing keys preserve these defaults:

```json
{"timezone":"Asia/Singapore","defaultDurationMinutes":60,"defaultAlertHour":22,"defaultAlertMinute":0}
```

Optional `eventCalendarId` / `reminderCalendarId` select an existing iCloud container by stable ID; omission uses Apple defaults. Invalid configuration stops operations. Do not overwrite user configuration during installation.

Omitted creation alerts mean the previous calendar day at the configured time. If past, use one hour before, then fifteen minutes before, then immediate, according to remaining time. Explicit alerts replace defaults; “再加/另外” means include both. `alerts:[]` removes notifications and clears native Early Reminder. Never invent a missing due date or location.
