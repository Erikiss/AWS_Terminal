# AWS_Terminal

Hilfsskripte, um das Projekt **`hmmrnn-stoc_reson`** aus Google Drive auf einen
frischen AWS-Rechner (Amazon Linux / `dnf`) zu holen und den Bootstrap
fortzusetzen.

## `repair_hmmrnn_download.sh`

Laedt den Drive-Ordner
[`hmmrnn-stoc_reson`](https://drive.google.com/drive/folders/19BP-JAQw6NWoTA4-ntrlWTh2ahdzO8w2)
robust herunter, validiert ihn und uebernimmt ihn erst dann nach
`/root/work/hmmrnn-stoc_reson`.

### Warum die alte Version nicht durchlief

Die vorherige Fassung lud den Ordner ueber `gdown --folder`. **`gdown` kann pro
Ordner nur maximal 50 Dateien laden** (harte Grenze der oeffentlichen Drive-Web-
Schnittstelle). Der Projektordner enthaelt aber deutlich mehr als 50 Dateien:

| Bereich | ca. Dateien |
|---|---|
| Wurzel (`aws_mechint.py`, `*.pth`, `main.ipynb`, README, …) | ~10 |
| `scripts/` (`rnn.py`, `mechint.py`, `manager.py`, …) | 12 + `__pycache__` |
| `fixed_point_finder/` (+ `paper/`, `examples/`, `test/`) | 11 + Unterordner |
| `aws_results/` (mehrere Laufordner à ~10 Dateien) | 25+ |
| `old_models/`, `Scratchpad/` | mehrere |

Dadurch brach `gdown` ab bzw. lieferte einen **unvollstaendigen** Ordner – das
`Skipping already downloaded file …` im Log war `gdown`, das sein 50-Dateien-
Budget beim erneuten Durchlaufen von `aws_results/` verbrauchte. Der Lauf
erreichte nie `Exit 0` und/oder die Validierung/der Bootstrap fand nicht alles.

### Was die neue Version anders macht

1. **Primaerer Weg: `rclone` ueber die echte Drive-API** – kein 50-Dateien-Limit,
   der komplette Ordner wird zuverlaessig gespiegelt.
2. **Token-Bootstrap ohne Henne-Ei-Problem:** Der `rclone`-Token liegt als
   *einzelne* Datei (`rclone_token_2aws.txt`) im Drive-Ordner. Eine Einzeldatei
   unterliegt **nicht** dem 50-Dateien-Limit, kann also mit `gdown` vorab geholt
   werden. Das Skript entpackt automatisch beide Formate
   (`{"token":"{...}"}` und blankes `{"access_token": …}`).
3. **Eigener Remote-Name `gdrive_dl`** (statt `gdrive`), damit ein bereits
   konfigurierter Upload-Remote nicht ueberschrieben wird.
4. **`gdown` bleibt nur noch Fallback** (mit `--remaining-ok`) und weist ehrlich
   darauf hin, dass das Ergebnis dann unvollstaendig sein kann.
5. Validierung und die sichere Uebernahme (Staging + Backup, `PROJECT` wird erst
   ganz am Ende angefasst) bleiben unveraendert.

### Token-Reihenfolge

Das Skript sucht den Token in dieser Reihenfolge:

1. Variable `RCLONE_TOKEN` im Skriptkopf (am sichersten – nichts wird aus Drive
   geladen).
2. Lokale Datei `RCLONE_TOKEN_FILE` (Standard `/root/rclone_token_2aws.txt`).
3. Automatischer Download der Datei `TOKEN_FILE_ID` aus dem Drive-Ordner.

### Benutzung

```bash
bash repair_hmmrnn_download.sh
```

Das Skript ist idempotent: erneutes Ausfuehren setzt einen Teil-Download fort
(`FRESH_START=0`). Fuer einen kompletten Neustart `FRESH_START=1` setzen.

### ⚠️ Sicherheitshinweis zum Token

`rclone_token_2aws.txt` enthaelt ein **gueltiges OAuth-Refresh-Token** fuer dein
Google Drive. Weil der Ordner „fuer alle mit dem Link“ freigegeben ist, kann
**jeder mit der Ordner-/Datei-ID dieses Token lesen** und damit auf dein Drive
zugreifen. Empfehlung:

- Token **nicht** im oeffentlich geteilten Drive-Ordner liegen lassen –
  stattdessen lokal auf dem AWS-Rechner ablegen (`RCLONE_TOKEN_FILE`) oder
  direkt in `RCLONE_TOKEN` setzen.
- Freigabe des Ordners einschraenken (nicht „anyone with the link“).
- Token bei Bedarf mit `rclone authorize "drive"` neu erzeugen (rotieren).

Der Token selbst wird von diesem Skript **niemals** ausgegeben oder in Git
eingecheckt – nur die (bereits ueber den geteilten Link erreichbare) Datei-ID.
