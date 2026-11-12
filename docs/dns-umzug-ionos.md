# Runbook: DNS-Zone abelisto.de von Route 53 zu IONOS

**Ziel:** IONOS verwaltet die Zone `abelisto.de`, damit die Managed Nextcloud auf einer Subdomain
(z. B. `cloud.abelisto.de`) zugeordnet werden kann. Die Landingpage bleibt bei AWS (S3 + CloudFront).

**Zielbild**

| Name | Typ | Ziel |
|---|---|---|
| `abelisto.de` | IONOS-Weiterleitung (301) | `https://www.abelisto.de` |
| `www.abelisto.de` | CNAME | `d1ou3iqo717q2j.cloudfront.net` |
| `cloud.abelisto.de` | (setzt IONOS bei Zuordnung der Nextcloud) | |
| Mail (MX, SPF, DKIM, autodiscover) | IONOS-Standard | unverändert |

## Ist-Zustand (geprüft am 2026-11-12)

- CloudFront-Distribution `E2XOV79KJVQ5X4` (`d1ou3iqo717q2j.cloudfront.net`)
  - Aliases: `abelisto.de`, `quineai.dev` – **`www.abelisto.de` fehlt**
  - Custom Error Response: 403 → `/index.html` (200) für den React BrowserRouter
- ACM-Zertifikat `fc474135-…` (us-east-1), SANs: `abelisto.de`, `quineai.dev` – **kein `www`**
- Folge: `https://www.abelisto.de` liefert heute schon einen TLS-Handshake-Fehler.
- `quineai.dev` liegt in einer eigenen Route-53-Zone und ist vom Umzug nicht betroffen.

**Nachtrag 2026-11-12:** Phase 1 ist erledigt (`www` als Alias, neues Zertifikat `10342122-…`).
Zusätzlich hängt die CloudFront Function `redirect-to-www-abelisto`
(Quelle im Landingpage-Repo `quine-landingpage`: `infra/cloudfront/redirect-to-www.js`) als viewer-request
am Default-Behavior: Jeder Host außer `www.abelisto.de` – also `abelisto.de` und `quineai.dev` – wird per 301
auf `https://www.abelisto.de` weitergeleitet, mit Pfad und Query-String.
Solange die Zone noch bei Route 53 liegt, erledigt also CloudFront die Apex-Weiterleitung. Nach dem Umzug
übernimmt die IONOS-Weiterleitung den Apex, für `quineai.dev` bleibt die Function zuständig.

Funktion ändern (im Landingpage-Repo ausführen):
```bash
aws cloudfront describe-function --name redirect-to-www-abelisto   # ETag holen
aws cloudfront update-function --name redirect-to-www-abelisto --if-match <ETag> \
  --function-config '{"Comment":"Redirect non-www hosts to www.abelisto.de","Runtime":"cloudfront-js-2.0"}' \
  --function-code fileb://infra/cloudfront/redirect-to-www.js
aws cloudfront publish-function --name redirect-to-www-abelisto --if-match <neues ETag>
```

## Phase 1 – www bei AWS lauffähig machen (vor dem Umzug, ohne Risiko)

1. Neues ACM-Zertifikat in **us-east-1** anfordern, DNS-Validierung:
   ```bash
   aws acm request-certificate --region us-east-1 --validation-method DNS \
     --domain-name abelisto.de \
     --subject-alternative-names www.abelisto.de quineai.dev
   ```
2. Validierungs-CNAMEs aus `aws acm describe-certificate` in die Route-53-Zonen eintragen
   (`abelisto.de` und `www.abelisto.de` in Zone `abelisto.de`, `quineai.dev` in Zone `quineai.dev`).
   Die Namen für `abelisto.de` und `quineai.dev` sind dieselben wie beim alten Zertifikat (gleicher Account);
   neu ist nur der Eintrag für `www`.
3. Wenn das Zertifikat `ISSUED` ist: In CloudFront `E2XOV79KJVQ5X4` den Alias `www.abelisto.de`
   ergänzen und das neue Zertifikat zuweisen.
4. `www` in Route 53 direkt auf CloudFront zeigen lassen (statt CNAME auf `abelisto.de`):
   `www.abelisto.de CNAME d1ou3iqo717q2j.cloudfront.net`
5. Test: `curl -sI https://www.abelisto.de` → `200`. Unterseite direkt testen, z. B. `/impressum`.
6. Altes Zertifikat erst löschen, wenn es von keiner Distribution mehr verwendet wird.

## Phase 2 – Vorbereitung bei IONOS

- [ ] Prüfen, ob die IONOS-Domainweiterleitung für `abelisto.de` **HTTPS** kann (braucht ein SSL-Zertifikat von IONOS für die Domain)
      und ob sie den Pfad mitnimmt (`abelisto.de/impressum` → `www.abelisto.de/impressum`).
      Ohne HTTPS bricht `https://abelisto.de` nach dem Umzug mit einem Zertifikatsfehler ab.
- [ ] DNSSEC: Ist im IONOS-Panel ein DS-Eintrag für `abelisto.de` hinterlegt? Wenn ja, zuerst entfernen
      und mindestens 2 Tage (DS-TTL) warten.
- [ ] TTLs in Route 53 sind bereits 300 s – passt.

## Phase 3 – Umschalten

1. Im IONOS-Panel bei `abelisto.de` die Nameserver von den AWS-NS auf **IONOS-Standard-Nameserver** umstellen.
2. Einträge im IONOS-DNS prüfen bzw. anlegen:

   | Name | Typ | Wert | Hinweis |
   |---|---|---|---|
   | `@` | MX | `mx00.ionos.de`, `mx01.ionos.de` (Prio 10) | IONOS-Standard, prüfen |
   | `@` | TXT | `v=spf1 include:_spf-eu.ionos.com ~all` | IONOS-Standard, prüfen |
   | `s1-ionos._domainkey` | CNAME | `s1.dkim.ionos.com` | IONOS-Standard, prüfen |
   | `s2-ionos._domainkey` | CNAME | `s2.dkim.ionos.com` | IONOS-Standard, prüfen |
   | `autodiscover` | CNAME | `adsredir.ionos.info` | IONOS-Standard, prüfen |
   | `_dmarc` | TXT | `v=DMARC1;p=quarantine;rua=mailto:postmaster@abelisto.de;ruf=mailto:postmaster@abelisto.de;` | **manuell** |
   | `www` | CNAME | `d1ou3iqo717q2j.cloudfront.net` | **manuell**, ersetzt IONOS-Default |
   | `_5d1006c964af72cc943f218b585e96e1` | CNAME | `_e7a3493c72d20ce90fc76749392e50cd.jkddzztszm.acm-validations.aws.` | **manuell**, ACM-Erneuerung |
   | `_<hash>.www` | CNAME | `…acm-validations.aws.` (aus Phase 1) | **manuell**, ACM-Erneuerung |
   | `@` | Weiterleitung | `https://www.abelisto.de` (301) | ersetzt IONOS-Default-A-Record |

3. Prüfen:
   ```bash
   dig +short NS abelisto.de
   dig +short www.abelisto.de
   dig +short MX abelisto.de
   dig +short TXT _dmarc.abelisto.de
   curl -sI https://abelisto.de        # 301 → https://www.abelisto.de/
   curl -sI https://www.abelisto.de    # 200
   ```
4. Mail senden und empfangen testen (DKIM/SPF-Ergebnis im Header prüfen).

## Phase 4 – Nextcloud und Aufräumen

1. Managed Nextcloud der Subdomain `cloud.abelisto.de` zuordnen.
2. Nach etwa 1 Woche ohne Probleme: Route-53-Zone `abelisto.de` löschen (Zone `quineai.dev` bleibt).
3. Alias `abelisto.de` kann in CloudFront bleiben (schadet nicht), solange der ACM-Validierungs-CNAME
   bei IONOS steht – sonst schlägt die automatische Erneuerung (vor 2027-03) fehl.
   Alternativ den Apex aus Alias und Zertifikat entfernen.
