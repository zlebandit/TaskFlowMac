#!/bin/bash
# Alfred Script Filter pour "fr" (fin de réunion)
#
# Lit le fichier JSON des réunions maintenu par l'app à chaque sync/lancement.
# L'app n'est plus sandboxée → le fichier est dans $HOME.

JSON_FILE="$HOME/.taskflowmac-meetings.json"

if [ -f "$JSON_FILE" ]; then
    cat "$JSON_FILE"
else
    echo '{"items": [{"uid": "error", "title": "Aucune réunion disponible", "subtitle": "Lance l'\''app et ouvre le popover pour sync.", "valid": false}]}'
fi
