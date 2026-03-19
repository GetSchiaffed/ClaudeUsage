#!/bin/bash
# watch.sh — Ricompila e riavvia ClaudeUsage.app automaticamente quando ClaudeUsage.swift cambia
#
# Uso:
#   chmod +x watch.sh
#   ./watch.sh
#
# Premi Ctrl+C per fermare il watcher (l'app continua a girare)

set -euo pipefail

SWIFT_FILE="ClaudeUsage.swift"
APP_NAME="ClaudeUsage"
APP_BUNDLE="${APP_NAME}.app"
BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

if [[ ! -f "$SWIFT_FILE" ]]; then
    echo "Errore: $SWIFT_FILE non trovato. Esegui questo script dalla stessa cartella."
    exit 1
fi

rebuild_and_restart() {
    echo ""
    echo "🔨 Modifica rilevata — ricompilazione in corso..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    if ./build.sh; then
        open "$APP_BUNDLE"
        echo "✓ App riavviata."
    else
        echo "✗ Compilazione fallita, app non riavviata."
    fi
}

# Build iniziale se il binario è più vecchio del sorgente o non esiste
if [[ ! -f "$BINARY" ]] || [[ "$SWIFT_FILE" -nt "$BINARY" ]]; then
    rebuild_and_restart
else
    echo "✓ Binario aggiornato, avvio diretto..."
    open "$APP_BUNDLE"
fi

echo ""
echo "👀 Monitoraggio $SWIFT_FILE in corso... (Ctrl+C per fermare)"
echo ""

LAST_MOD=$(stat -f "%m" "$SWIFT_FILE")

while true; do
    sleep 2
    CURRENT_MOD=$(stat -f "%m" "$SWIFT_FILE" 2>/dev/null) || continue
    if [[ "$CURRENT_MOD" != "$LAST_MOD" ]]; then
        LAST_MOD="$CURRENT_MOD"
        rebuild_and_restart
    fi
done
