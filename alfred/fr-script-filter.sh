#!/bin/bash
# Alfred Script Filter pour "fr" (fin de réunion)
#
# Smart : auto-détecte l'événement si l'enregistrement a été démarré
# depuis l'app avec un rdv spécifique (via UserDefaults).
# → Affiche cet événement en tête de liste (⏹ auto-détecté ✨)
# → Suivi des autres réunions du jour pour override éventuel.
#
# IMPORTANT : l'action Alfred connectée doit être :
#   taskflowmac://stopassign?id={query}
# (stopassign gère stop + assign en une seule commande)

BUNDLE_ID="com.clementziza.taskflowmac"
JSON_FILE="$HOME/.taskflowmac-meetings.json"

# Lire l'état d'enregistrement depuis UserDefaults
IS_ACTIVE=$(defaults read "$BUNDLE_ID" "recording.isActive" 2>/dev/null || echo "0")
EVENT_ID=$(defaults read "$BUNDLE_ID" "recording.eventId" 2>/dev/null || echo "")
EVENT_TITLE=$(defaults read "$BUNDLE_ID" "recording.eventTitle" 2>/dev/null || echo "")

# Si enregistrement actif avec événement connu (pas un enregistrement libre)
if [ "$IS_ACTIVE" = "1" ] && [ -n "$EVENT_ID" ] && [ "$EVENT_ID" != "free-recording" ]; then
    /usr/bin/python3 - "$EVENT_ID" "$EVENT_TITLE" "$JSON_FILE" << 'PYEOF'
import json, sys

event_id = sys.argv[1]
event_title = sys.argv[2]
json_file = sys.argv[3]

# Item auto-détecté en tête
items = [{
    "uid": "auto-" + event_id,
    "title": "\u23f9 " + event_title,
    "subtitle": "Arr\u00eater et transcrire (auto-d\u00e9tect\u00e9 \u2728)",
    "arg": event_id,
    "icon": {"path": "icon.png"}
}]

# Ajouter les autres réunions (sauf celle déjà auto-détectée)
try:
    with open(json_file) as f:
        data = json.load(f)
        for item in data.get("items", []):
            if item.get("uid") != event_id and item.get("arg") != event_id:
                items.append(item)
except:
    pass

print(json.dumps({"items": items}))
PYEOF
else
    # Pas d'auto-détection → toutes les réunions du jour
    if [ -f "$JSON_FILE" ]; then
        cat "$JSON_FILE"
    else
        echo '{"items": [{"uid": "error", "title": "Aucune réunion disponible", "subtitle": "Lance l'\''app et ouvre le popover pour sync.", "valid": false}]}'
    fi
fi
