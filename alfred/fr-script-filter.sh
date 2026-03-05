#!/bin/bash
# Alfred Script Filter pour "fr" (fin de réunion)
#
# Lit le fichier JSON des réunions (maintenu par l'app à chaque sync)
# et l'affiche dans Alfred. La sélection déclenchera stopassign.
#
# L'app écrit ~/.taskflowmac-meetings.json à chaque sync automatiquement.

JSON_FILE="$HOME/.taskflowmac-meetings.json"

if [ -f "$JSON_FILE" ]; then
    cat "$JSON_FILE"
else
    echo '{"items": [{"uid": "error", "title": "Aucune r\u00e9union disponible", "subtitle": "L'\''app n'\''a pas encore sync. Ouvre le popover une fois.", "valid": false}]}'
fi
