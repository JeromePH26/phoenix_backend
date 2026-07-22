PHÖNIX BACKEND ASSET BUILD-FIX

Ersetzen:
lib/src/services/football_asset_service.dart

Grund:
PhoenixDatabase besitzt aktuell keine Methode saveFootballAsset().
Die Ersatzdatei liest vorhandene Cache-Bilder weiterhin aus der Datenbank,
speichert neue Bilder aber vorübergehend nicht. Dadurch kompiliert das Backend.

Danach:
1. Datei in GitHub ersetzen
2. Commit erstellen
3. Railway: Deploy Latest Commit
4. Nach erfolgreichem Deploy Tennis-Endpunkt erneut testen
