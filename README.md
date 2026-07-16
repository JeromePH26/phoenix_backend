# PHÖNIX Backend – Railway Stage 1

Dieses Paket ist der erste echte Serverstand der kompletten PHÖNIX-App.

## Bereits funktionsfähig

- `GET /health`
- PostgreSQL-Verbindung und automatische Tabellenmigration
- `GET /api/football/matches/today`
- `GET /api/football/matches/YYYY-MM-DD`
- `GET /api/tennis/matches/today`
- `GET /api/tennis/matches/YYYY-MM-DD`
- `GET /api/tips/today` als vorbereitete Route
- API-Schlüssel liegen ausschließlich als Railway-Variablen auf dem Server
- Dockerfile und Railway-Healthcheck

Die Fußball- und Tennis-Vollanalyse wird in Stage 2 in diesen Serverstand übertragen. Dieser erste Stand prüft zuerst sicher: Deployment, Datenbank, Schlüssel und App-zu-Server-Verbindung.

## Railway installieren

1. Neues GitHub-Repository erstellen, z. B. `phoenix-backend`.
2. Den Inhalt dieses Ordners in das Repository hochladen.
3. Railway-Projekt öffnen und `New Service -> GitHub Repo` wählen.
4. Das Repository verbinden.
5. PostgreSQL im selben Railway-Projekt hinzufügen.
6. Im Backend-Service unter `Variables` anlegen:

```text
API_FOOTBALL_KEY=dein_key
SPORTRADAR_TENNIS_API_KEY=dein_key
SPORTRADAR_TENNIS_ACCESS_LEVEL=trial
SPORTRADAR_TENNIS_LANGUAGE=de
PHOENIX_ADMIN_TOKEN=eine_lange_zufaellige_zeichenfolge
```

`DATABASE_URL` wird über Railway automatisch vom PostgreSQL-Service referenziert. Falls nicht automatisch vorhanden: Im Backend-Service eine Variable Reference auf `Postgres.DATABASE_URL` anlegen.

7. Unter `Settings -> Networking` eine öffentliche Domain erzeugen.
8. Öffnen:

```text
https://DEINE-RAILWAY-DOMAIN/health
```

Erwartete Antwort:

```json
{
  "status": "ok",
  "service": "phoenix-backend",
  "database": {"configured": true, "connected": true},
  "providers": {"football": true, "tennis": true}
}
```

## API testen

```text
https://DEINE-DOMAIN/api/football/matches/today
https://DEINE-DOMAIN/api/tennis/matches/today
```

## Sicherheit

- `.env` niemals auf GitHub hochladen.
- API-Schlüssel niemals in Flutter eintragen.
- `PHOENIX_ADMIN_TOKEN` lang und zufällig wählen.
- PostgreSQL nicht öffentlich freigeben.

## Flutter-Verbindung

Unter `flutter_client/lib/services/phoenix_server_api.dart` liegt der erste Client-Service. In Flutter wird später nur die Railway-Adresse eingetragen:

```dart
final api = PhoenixServerApi(
  baseUrl: 'https://deine-domain.up.railway.app',
);
```

## Stage 2

- Fußball-Engine und Monte Carlo auf den Server
- Tennis-Phasen 1–5 und 100.000 Monte Carlo auf den Server
- Analysen in PostgreSQL speichern und nach Matchbeginn sperren
- automatische Tagesscans
- Ergebnisabgleich
- Tipp des Tages
- Flutter-Repositories vollständig auf PHÖNIX API umstellen
