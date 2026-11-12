# Nextcloud Talk High Performance Backend (HPB) auf IONOS Managed Kubernetes

Betreibt das Nextcloud Talk HPB für die IONOS Managed Nextcloud.

## Architektur

Ein Pod auf einem fest zugeordneten Node (Label `talk-hpb=true`), erreichbar über
einen Service vom Typ `LoadBalancer` mit fester IP `217.160.35.119` ([service.yaml](service.yaml)):

| Container | Inhalt | Ports (über den Service) |
|-----------|--------|--------------------------|
| `talk` (`ghcr.io/nextcloud-releases/aio-talk`) | Signaling-Server, Janus, NATS, eturnal (TURN) | 3478 TCP+UDP öffentlich, 8081 nur pod-intern |
| `caddy` | TLS-Terminierung mit Let's Encrypt, Proxy auf 127.0.0.1:8081 | 80, 443 TCP |

Das entspricht dem Docker-Setup von Nextcloud AIO, bei dem nur 3478 veröffentlicht
wird. Ingress-Controller und cert-manager braucht es so nicht.

Hinweise zu IONOS MK8s:

- **Feste IP nur über den LoadBalancer-Service.** IONOS hängt die reservierte IP als
  zusätzliche IP an einen Node und zieht sie beim Node-Austausch mit um. Die
  *Public IPs* im Node Pool sind dafür ungeeignet: IONOS verteilt sie bei jedem
  Austausch zufällig neu auf die Nodes.
- `externalTrafficPolicy: Local` erhält die echte Client-IP (wichtig für TURN).
  TCP und UDP auf 3478 im selben Service funktionieren (getestet).
- `hostNetwork` geht **nicht**: IONOS belegt auf jedem Node Port 8081
  (`nginx-proxy` für den API-Server), und den nutzt auch der Signaling-Server fest.
- Immer mit **Server-Side Apply** ausrollen (`--server-side`). Das clientseitige
  `kubectl apply` führt Ports nur über `containerPort` zusammen und kann dabei
  Einträge für 3478/UDP verlieren (3478/TCP und 3478/UDP haben denselben containerPort).

## Voraussetzungen im DCD

1. **Feste IP für den Service:** Im IP Manager eine IP reservieren (gleiche Location
   wie der Cluster) und in `service.yaml` als `loadBalancerIP` eintragen. Diese IP
   darf **nicht** unter *Public IPs* eines Node Pools stehen.
2. **Label am Node Pool:** `talk-hpb=true` (im Node Pool, nicht per `kubectl label`,
   sonst ist es nach einem Node-Austausch weg).
3. **DNS:** A-Record `talk.abelisto.de` → `217.160.35.119` (einmalig, bleibt fest).
4. **Firewall/Security:** 80/TCP, 443/TCP, 3478/TCP und 3478/UDP müssen von außen
   erreichbar sein.
5. **Sizing:** mindestens 2 vCPU / 4 GB RAM für kleine Gruppen. Janus ist CPU-lastig.

## Deployment

1. Kubeconfig des Clusters aus dem DCD herunterladen und aktivieren:

   ```bash
   export KUBECONFIG=~/Downloads/kubeconfig.yaml
   ```

2. `config.env` anpassen (`NC_DOMAIN`, `TALK_HOST`).
3. Secrets erzeugen (legt `secrets.env` an, wird nicht committet):

   ```bash
   ./generate-secrets.sh
   ```

4. Ausrollen:

   ```bash
   kubectl apply -k . --server-side --force-conflicts
   ```

5. Prüfen:

   ```bash
   kubectl -n talk-hpb get pods -o wide
   ```

   ```bash
   curl https://talk.abelisto.de/api/v1/welcome
   ```

   Erwartet wird eine JSON-Antwort mit `"nextcloud-spreed-signaling"`.

## Nextcloud konfigurieren

Als Admin unter *Verwaltungseinstellungen → Talk*:

| Feld | Wert |
|------|------|
| STUN-Server | `talk.abelisto.de:3478` |
| TURN-Server | `turn:` + `talk.abelisto.de:3478`, Secret = `TURN_SECRET`, Protokoll UDP und TCP |
| Hochleistungs-Backend | `https://talk.abelisto.de`, Secret = `SIGNALING_SECRET`, SSL-Zertifikat prüfen: an |

Danach sollte Talk die HPB-Prüfung grün anzeigen. Falls das Admin-UI der Managed
Nextcloud diese Felder nicht freigibt, muss der IONOS-Support sie setzen.

## Betrieb

- **Updates automatisch:** Der CronJob `talk-hpb-weekly-restart`
  ([cronjob-restart.yaml](cronjob-restart.yaml)) startet das HPB jeden Sonntag um
  04:00 (Europe/Berlin) neu und zieht dabei das neueste `aio-talk`-Image (`latest`).
  Laufende Anrufe brechen dabei kurz ab.
- **Updates manuell:** `kubectl -n talk-hpb rollout restart deploy/talk-hpb`
  oder den CronJob sofort auslösen:
  `kubectl -n talk-hpb create job --from=cronjob/talk-hpb-weekly-restart restart-now`
- **Automatik pausieren:** `kubectl -n talk-hpb patch cronjob talk-hpb-weekly-restart -p '{"spec":{"suspend":true}}'`
- **Caddy** ist auf einen festen Tag gepinnt. Zum Aktualisieren den Tag in
  `deployment.yaml` ändern und neu ausrollen.
- **Logs:** `kubectl -n talk-hpb logs deploy/talk-hpb -c talk`
- **Secrets rotieren:** `secrets.env` löschen, `./generate-secrets.sh`, `kubectl apply -k . --server-side --force-conflicts`,
  dann die neuen Werte in Nextcloud eintragen.
