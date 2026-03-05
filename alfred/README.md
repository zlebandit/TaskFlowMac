# TaskFlowMac — Workflow Alfred

## Installation rapide

1. Ouvre Alfred Preferences → Workflows
2. Clique sur le `+` en bas → Blank Workflow
3. Nomme-le "TaskFlowMac"
4. Ajoute les éléments ci-dessous

## Hotkeys à configurer

### ⌘⇧R — Toggle enregistrement (start/stop)
- Type : Hotkey → Open URL
- URL : `taskflowmac://toggle`

### ⌘⇧P — Toggle pause (pause/resume)
- Type : Hotkey → Open URL
- URL : `taskflowmac://pausetoggle`

### ⌘⇧X — Annuler l'enregistrement
- Type : Hotkey → Open URL
- URL : `taskflowmac://cancel`

## Keyword "tf" — Liste des commandes

1. Ajoute un **Script Filter** avec keyword `tf`
2. Colle le script suivant (Language: `/bin/bash`) :

```bash
cat << 'EOF'
{"items": [
  {
    "uid": "toggle",
    "title": "Toggle Recording",
    "subtitle": "Démarrer ou arrêter l'enregistrement (⌘⇧R)",
    "arg": "taskflowmac://toggle",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "pause",
    "title": "Toggle Pause",
    "subtitle": "Mettre en pause ou reprendre (⌘⇧P)",
    "arg": "taskflowmac://pausetoggle",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "start",
    "title": "Start Recording",
    "subtitle": "Démarrer l'enregistrement de la réunion en cours",
    "arg": "taskflowmac://start",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "stop",
    "title": "Stop Recording",
    "subtitle": "Arrêter et envoyer pour transcription",
    "arg": "taskflowmac://stop",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "pause-only",
    "title": "Pause",
    "subtitle": "Mettre en pause l'enregistrement",
    "arg": "taskflowmac://pause",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "resume",
    "title": "Resume",
    "subtitle": "Reprendre l'enregistrement",
    "arg": "taskflowmac://resume",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "cancel",
    "title": "Cancel Recording",
    "subtitle": "Annuler et supprimer l'enregistrement (⌘⇧X)",
    "arg": "taskflowmac://cancel",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "status",
    "title": "Status",
    "subtitle": "Afficher l'état actuel (debug log)",
    "arg": "taskflowmac://status",
    "icon": {"path": "icon.png"}
  }
]}
EOF
```

3. Connecte le Script Filter à une action **Open URL** (avec `{query}` comme URL)

## Alternative : installation en une ligne

Si tu veux juste les raccourcis sans le keyword, tu peux aussi utiliser le Terminal :

```bash
# Toggle recording
open "taskflowmac://toggle"

# Toggle pause
open "taskflowmac://pausetoggle"

# Cancel
open "taskflowmac://cancel"
```

Et associer ces commandes à des raccourcis via Automator ou Raycast.
