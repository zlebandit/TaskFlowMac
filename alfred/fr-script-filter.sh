#!/bin/bash
# Alfred Script Filter pour "fr" (fin de réunion)
#
# Lit le fichier JSON des réunions maintenu par l'app à chaque sync/lancement.
# Le fichier est dans /tmp/ car l'app est sandboxée (home ≠ $HOME).

JSON_FILE="/tmp/.taskflowmac-meetings.json"

if [ -f "$JSON_FILE" ]; then
    cat "$JSON_FILE"
else
    echo '{"items": [{"uid": "error", "title": "Aucune réunion disponible", "subtitle": "Lance l'\''app et ouvre le popover pour sync.", "valid": false}]}'
fi
