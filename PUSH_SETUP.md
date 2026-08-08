# PHÖNIX push setup

Set these Railway variables on the backend service:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_SERVICE_ACCOUNT_JSON` — the complete Firebase service-account JSON
- existing `DATABASE_URL` and `API_FOOTBALL_KEY`

On startup the backend migrates PostgreSQL to schema version 3 and starts the
favorite live monitor. The monitor runs every five seconds, but the existing
football-provider cache limits upstream live calls to one set per fixture every
15 seconds.

The Flutter build must receive:

```text
--dart-define=FIREBASE_PROJECT_ID=...
--dart-define=FIREBASE_API_KEY=...
--dart-define=FIREBASE_APP_ID=...
--dart-define=FIREBASE_SENDER_ID=...
--dart-define=FIREBASE_STORAGE_BUCKET=...
```

The service account is backend-only and must never be included in the app.
