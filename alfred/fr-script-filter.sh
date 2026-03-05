#!/bin/bash
# Alfred Script Filter pour "fr" (fin de réunion)
# 1. Stoppe l'enregistrement en cours via URL scheme
# 2. Déclenche l'écriture du JSON des meetings
# 3. Lit le fichier JSON et l'affiche dans Alfred

# Stopper l'enregistrement + écrire le JSON des meetings
open "taskflowmac://stop"
open "taskflowmac://meetings"

# Attendre que l'app écrive le fichier (max 1s)
JSON_FILE="$TMPDIR/taskflowmac-meetings.json"
for i in $(seq 1 10); do
    if [ -f "$JSON_FILE" ] && [ "$(stat -f%m "$JSON_FILE")" -gt "$(($(date +%s) - 2))" ]; then
        break
    fi
    sleep 0.1
done

# Lire et afficher le JSON
if [ -f "$JSON_FILE" ]; then
    cat "$JSON_FILE"
else
    cat << 'EOF'
{"items": [{"uid": "error", "title": "Aucune réunion disponible", "subtitle": "L'app n'a pas répondu. Vérifie qu'elle est lancée.", "valid": false}]}
EOF
fi
