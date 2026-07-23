sudo bash <<'BASH'
set -Eeuo pipefail

# ============================================================
#  KONFIGURATION
# ============================================================

PROJECT="/root/work/hmmrnn-stoc_reson"
TEMP="/root/work/hmmrnn-stoc_reson.download"
DL_VENV="/root/work/.gdown6"
FOLDER_ID="19BP-JAQw6NWoTA4-ntrlWTh2ahdzO8w2"
DRIVE_URL="https://drive.google.com/drive/folders/${FOLDER_ID}?usp=sharing"
DOWNLOAD_LOG="/root/gdown6_download.log"
STAMP="$(date -u +%Y%m%d_%H%M%S)"

# Teil-Download behalten und fortsetzen (1 = alles verwerfen und neu laden)
FRESH_START=0

# Retry-Verhalten fuer den gdown-Fallback (nur relevant, wenn rclone scheitert)
MAX_TRIES=8
SLEEP_BASE=20

# ------------------------------------------------------------
#  rclone-Token  (der robuste Weg ohne 50-Dateien-Limit)
# ------------------------------------------------------------
# Reihenfolge, in der der Token gesucht wird:
#   1. Variable RCLONE_TOKEN unten (am sichersten -> nichts wird aus Drive geladen)
#   2. Lokale Datei RCLONE_TOKEN_FILE, falls vorhanden
#   3. Automatischer Download der Datei TOKEN_FILE_ID aus dem Drive-Ordner
#
# Der Token ist das komplette JSON aus  rclone authorize "drive"  ODER die
# Wrapper-Form  {"token":"{...}"}  -- beides wird automatisch erkannt.
RCLONE_TOKEN=""
RCLONE_TOKEN_FILE="/root/rclone_token_2aws.txt"
TOKEN_FILE_ID="13MgcJpN1M4VnILUof_jZwhcTGYDWpmTn"   # rclone_token_2aws.txt in der Drive-Wurzel

# Eigener Remote-Name, damit ein evtl. vorhandener 'gdrive:'-Remote
# (z.B. fuer den Upload der Ergebnisse) NICHT ueberschrieben wird.
RCLONE_REMOTE="gdrive_dl"

# ============================================================

echo
echo "===================================================="
echo " REPARATUR: DRIVE-DOWNLOAD  (Lauf ${STAMP})"
echo "===================================================="
echo

fail() {
    echo
    echo "FEHLER: $*"
    echo
    echo "--- Letzte 60 Zeilen des Download-Logs -----------"
    tail -n 60 "$DOWNLOAD_LOG" 2>/dev/null || true
    echo
    echo "--- Bisher vorhandene Struktur ------------------"
    find "$TEMP" -maxdepth 4 -printf "%y  %p\n" 2>/dev/null | sort | head -n 200 || true
    echo
    echo "Dateien im Temp-Ordner: $(find "$TEMP" -type f 2>/dev/null | wc -l)"
    echo
    echo "WICHTIG: '$PROJECT' wurde NICHT angefasst."
    echo "Erneutes Ausfuehren setzt den Download fort (FRESH_START=0)."
    exit 1
}

count_files() { find "$TEMP" -type f 2>/dev/null | wc -l; }

if [ "$FRESH_START" -eq 1 ]; then
    echo "FRESH_START=1 -> verwerfe bisherigen Teil-Download"
    rm -rf "$TEMP"
fi

mkdir -p "$TEMP"
: > "$DOWNLOAD_LOG"

DOWNLOAD_OK=0

# ============================================================
#  0. Downloader-Umgebung (gdown fuer Einzeldatei-Token + Fallback)
# ============================================================

echo "=== 0. Downloader-Umgebung vorbereiten ==="

if [ ! -x "$DL_VENV/bin/gdown" ]; then
    dnf install -y python3.11 python3.11-pip
    python3.11 -m venv "$DL_VENV"
    "$DL_VENV/bin/python" -m pip install --upgrade pip
    "$DL_VENV/bin/python" -m pip install "gdown>=6,<7"
else
    echo "Vorhandene gdown-Umgebung wird wiederverwendet."
fi

GDOWN="$DL_VENV/bin/gdown"
PYTHON="$DL_VENV/bin/python"

echo -n "Gdown-Version: "
"$GDOWN" --version

# ============================================================
#  1. rclone bereitstellen und Token besorgen
# ============================================================

echo
echo "=== 1. rclone bereitstellen ==="

if ! command -v rclone >/dev/null 2>&1; then
    dnf install -y rclone 2>/dev/null \
        || curl -fsSL https://rclone.org/install.sh | bash
fi
rclone version | head -n1

# --- Token beschaffen ---------------------------------------
if [ -z "$RCLONE_TOKEN" ] && [ -s "$RCLONE_TOKEN_FILE" ]; then
    echo "rclone-Token wird aus lokaler Datei gelesen: $RCLONE_TOKEN_FILE"
    RCLONE_TOKEN_SRC="$RCLONE_TOKEN_FILE"
fi

if [ -z "$RCLONE_TOKEN" ] && [ -z "${RCLONE_TOKEN_SRC:-}" ] && [ -n "$TOKEN_FILE_ID" ]; then
    echo "rclone-Token wird als Einzeldatei aus Drive geladen"
    echo "(Einzeldatei -> KEIN 50-Dateien-Limit von gdown)."
    RCLONE_TOKEN_SRC="$TEMP/.rclone_token_raw.json"
    rm -f "$RCLONE_TOKEN_SRC"
    "$GDOWN" "https://drive.google.com/uc?id=${TOKEN_FILE_ID}" \
        -O "$RCLONE_TOKEN_SRC" 2>&1 | tee -a "$DOWNLOAD_LOG" || true
    [ -s "$RCLONE_TOKEN_SRC" ] || RCLONE_TOKEN_SRC=""
fi

# Token aus der Quelldatei extrahieren (Wrapper {"token":"{...}"} ODER blankes JSON)
if [ -z "$RCLONE_TOKEN" ] && [ -n "${RCLONE_TOKEN_SRC:-}" ] && [ -s "$RCLONE_TOKEN_SRC" ]; then
    chmod 600 "$RCLONE_TOKEN_SRC" 2>/dev/null || true
    RCLONE_TOKEN="$("$PYTHON" - "$RCLONE_TOKEN_SRC" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read().strip()
try:
    obj = json.loads(raw)
except Exception:
    print(raw)          # kein JSON -> unveraendert durchreichen
    sys.exit(0)
# Wrapper-Form {"token": "{...}"} entpacken, sonst direkt verwenden
if isinstance(obj, dict) and "token" in obj and "access_token" not in obj:
    tok = obj["token"]
    print(tok if isinstance(tok, str) else json.dumps(tok))
else:
    print(json.dumps(obj))
PY
)"
    rm -f "$RCLONE_TOKEN_SRC"
fi

# ============================================================
#  2. WEG A: rclone ueber die echte Drive-API (kein Datei-Limit)
# ============================================================

if [ -n "$RCLONE_TOKEN" ]; then

    echo
    echo "=== 2. Download via rclone (Drive-API, kein 50-Dateien-Limit) ==="

    # Frisch konfigurieren, damit ein alter/kaputter Remote nicht stoert.
    rclone config delete "$RCLONE_REMOTE" >/dev/null 2>&1 || true
    # stdout nach /dev/null: rclone gibt die Config (inkl. Token) sonst aus.
    rclone config create "$RCLONE_REMOTE" drive \
        scope=drive.readonly \
        token="$RCLONE_TOKEN" >/dev/null

    set +e
    rclone copy -P \
        --drive-root-folder-id "$FOLDER_ID" \
        --exclude "rclone_token_2aws.txt" \
        --retries 10 \
        --low-level-retries 20 \
        --transfers 4 \
        --checkers 8 \
        "${RCLONE_REMOTE}:" "$TEMP" 2>&1 | tee -a "$DOWNLOAD_LOG"
    RC="${PIPESTATUS[0]}"
    set -e

    echo
    echo "rclone Exit-Code: ${RC}   |   Dateien bisher: $(count_files)"

    if [ "$RC" -eq 0 ]; then
        echo "rclone meldet vollstaendigen Download."
        DOWNLOAD_OK=1
    else
        echo "WARNUNG: rclone-Download nicht sauber beendet (Exit ${RC})."
        echo "Moegliche Ursache: abgelaufener/zurueckgezogener Token."
        echo "Es wird nun der gdown-Fallback versucht."
    fi

else
    echo
    echo "HINWEIS: Kein rclone-Token verfuegbar -> nur gdown-Fallback moeglich."
    echo "gdown kann pro Ordner nur 50 Dateien laden; der Download kann"
    echo "unvollstaendig bleiben. Fuer einen vollstaendigen Lauf bitte einen"
    echo "rclone-Token hinterlegen (siehe Kopf dieses Skripts)."
fi

# ============================================================
#  3. WEG B (Fallback): gdown in einer Retry-Schleife
# ============================================================

if [ "$DOWNLOAD_OK" -ne 1 ]; then

    echo
    echo "=== 3. Fallback: gdown-Ordner-Download mit Wiederholungen ==="
    echo "gdown bricht beim ersten blockierten File ab; --continue ueberspringt"
    echo "bereits geladene Dateien. ACHTUNG: harte Grenze von 50 Dateien pro"
    echo "Ordner -- der Download kann dadurch unvollstaendig bleiben."
    echo

    GDOWN_ARGS=(--folder --continue)
    if "$GDOWN" --help 2>&1 | grep -q -- "--remaining-ok"; then
        GDOWN_ARGS+=(--remaining-ok)
    fi

    LAST_COUNT=-1
    STALL=0

    for TRY in $(seq 1 "$MAX_TRIES"); do

        echo "---------- Versuch ${TRY}/${MAX_TRIES} ----------"

        set +e
        "$GDOWN" "${GDOWN_ARGS[@]}" \
            "$DRIVE_URL" -O "$TEMP" 2>&1 | tee -a "$DOWNLOAD_LOG"
        RC="${PIPESTATUS[0]}"
        set -e

        NOW="$(count_files)"
        echo
        echo "Exit-Code: ${RC}   |   Dateien bisher: ${NOW}"

        if [ "$RC" -eq 0 ]; then
            echo "gdown meldet vollstaendigen Download."
            DOWNLOAD_OK=1
            break
        fi

        if [ "$NOW" -le "$LAST_COUNT" ]; then
            STALL=$((STALL + 1))
        else
            STALL=0
        fi
        LAST_COUNT="$NOW"

        if [ "$STALL" -ge 3 ]; then
            echo "Drei Versuche ohne jeden Fortschritt - Schleife beendet."
            break
        fi

        WAIT=$((SLEEP_BASE * TRY))
        echo "Warte ${WAIT}s, damit das Google-Ratelimit abkuehlt..."
        sleep "$WAIT"
        echo
    done
fi

# ============================================================
#  4. VALIDIERUNG  (vor jeder Aenderung am Projekt)
# ============================================================

echo
echo "=== 4. Validierung ==="

FILE_COUNT="$(count_files)"
echo "Heruntergeladene Dateien insgesamt: ${FILE_COUNT}"

[ "$FILE_COUNT" -gt 0 ] || fail "Keine einzige Datei heruntergeladen."

RNN="$(find "$TEMP" -type f -name 'rnn.py' -printf '%d\t%p\n' 2>/dev/null \
       | sort -n | head -n1 | cut -f2 || true)"

[ -n "$RNN" ] || fail "rnn.py wurde nirgends im Download gefunden."

RNN_DIR="$(dirname "$RNN")"

if [ "$(basename "$RNN_DIR")" = "scripts" ]; then
    ROOT="$(dirname "$RNN_DIR")"
else
    ROOT="$RNN_DIR"
fi

MECHINT="$(find "$ROOT" -maxdepth 2 -type f -name 'aws_mechint.py' -print -quit || true)"
[ -n "$MECHINT" ] || fail "aws_mechint.py fehlt unterhalb von ${ROOT}."

MODEL="$(find "$ROOT" -maxdepth 2 -type f -name '*.pth' -print -quit || true)"
[ -n "$MODEL" ] || fail "Keine .pth-Modelldatei unterhalb von ${ROOT}."

if [ "$DOWNLOAD_OK" -ne 1 ]; then
    echo
    echo "HINWEIS: Der Download hat nie sauber mit Exit 0 beendet."
    echo "Die Pflichtdateien sind da, der Ordner kann aber unvollstaendig sein."
    echo "Fuer Vollstaendigkeit einen rclone-Token hinterlegen und erneut starten."
fi

echo
echo "Projektwurzel im Download: ${ROOT}"
echo "  rnn.py         -> ${RNN}"
echo "  aws_mechint.py -> ${MECHINT}"
echo "  Modell         -> ${MODEL}"

# ============================================================
#  5. SICHERE UEBERNAHME
# ============================================================

echo
echo "=== 5. Projekt sicher uebernehmen ==="

STAGING="${PROJECT}.new.${STAMP}"
rm -rf "$STAGING"
mv "$ROOT" "$STAGING"

if [ -e "$PROJECT" ]; then
    BACKUP="${PROJECT}.bak.${STAMP}"
    mv "$PROJECT" "$BACKUP"
    echo "Altes Projekt gesichert unter: ${BACKUP}"
    echo "(Erst loeschen, wenn der neue Lauf erfolgreich war.)"
fi

mv "$STAGING" "$PROJECT"
rm -rf "$TEMP"

echo
echo "Uebernommen nach: ${PROJECT}"
echo
find "$PROJECT" -maxdepth 2 -type f -printf "%p\n" | sort | head -n 100

# ============================================================
#  6. BOOTSTRAP
# ============================================================

echo
echo "=== 6. Bootstrap fortsetzen ==="

if [ ! -f /root/bootstrap_hmmrnn_universal.sh ]; then
    echo "WARNUNG: /root/bootstrap_hmmrnn_universal.sh fehlt."
    echo "Das Projekt liegt aber vollstaendig unter ${PROJECT}."
    exit 0
fi

bash /root/bootstrap_hmmrnn_universal.sh
BASH
