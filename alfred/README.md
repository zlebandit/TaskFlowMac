# TaskFlowMac — Workflow Alfred

## Nouveau flux (dr / fr)

L'approche recommandée utilise deux keywords Alfred :

- **`dr`** = Début de Réunion → lance un enregistrement libre
- **`fr`** = Fin de Réunion → stoppe l'enregistrement, affiche les réunions du jour, sélection → upload

### 1. Keyword `dr` — Début de réunion

1. Ajoute un **Keyword** dans Alfred : `dr`
   - Title : "Début de réunion"
   - Subtitle : "Lancer l'enregistrement"
2. Connecte-le à une action **Open URL** : `taskflowmac://record`

C'est tout ! `dr` lance un enregistrement libre, sans l'affecter à une réunion.

### 2. Keyword `fr` — Fin de réunion

Celui-ci est un **Script Filter** qui affiche la liste des réunions.

1. Ajoute un **Script Filter** avec keyword `fr`
   - Title : "Fin de réunion"
   - Language : `/bin/bash`
   - Script : colle le contenu de `fr-script-filter.sh` (voir ci-dessous)
   - Cocher "Alfred filters results" (désactivé) — on veut tous les résultats

2. Connecte le Script Filter à une action **Open URL** avec URL : `taskflowmac://stopassign?id={query}`
   - ⚠️ Utiliser `stopassign` (pas `assign`) — il gère stop + assign en une seule commande

#### Script pour `fr` (smart — auto-détection) :

Le script lit les UserDefaults de l'app pour détecter si l'enregistrement a été
démarré depuis l'app avec un événement spécifique. Si oui, cet événement est
affiché en tête de liste avec ✨. Sinon, toutes les réunions du jour sont affichées.

Voir `fr-script-filter.sh` pour le code complet.

### Flux complet

#### Cas 1 : Enregistrement démarré depuis l'app (avec événement)
```
App → Swipe sur "Réunion Client X" → 🎙 Transcrire
  → L'enregistrement démarre (🔴 visible dans la menubar)

⌘Space → fr
  → Alfred affiche "⏹ Réunion Client X" en premier (auto-détecté ✨)
  → Entrée → stopassign → Upload automatique → Transcription
```

#### Cas 2 : Enregistrement libre (dr)
```
⌘Space → dr → Entrée
  → L'enregistrement démarre (🔴 visible dans la menubar)

⌘Space → fr
  → Alfred affiche toutes les réunions du jour
  → Tu sélectionnes la bonne réunion → Entrée
  → stopassign → Upload automatique → Transcription
```

## Raccourcis optionnels (Hotkeys)

Ces hotkeys sont optionnels, `dr` et `fr` suffisent :

| Hotkey | URL Scheme | Action |
|--------|-----------|--------|
| ⌘⇧P | `taskflowmac://pausetoggle` | Toggle pause/resume |
| ⌘⇧X | `taskflowmac://cancel` | Annuler l'enregistrement |

## Keyword `tf` — Toutes les commandes

Pour les power users, un keyword `tf` donne accès à toutes les commandes :

1. Ajoute un **Script Filter** avec keyword `tf`
2. Colle le script suivant (Language: `/bin/bash`) :

```bash
cat << 'EOF'
{"items": [
  {
    "uid": "record",
    "title": "🎙️ Enregistrer (libre)",
    "subtitle": "Démarrer un enregistrement sans événement",
    "arg": "taskflowmac://record",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "start",
    "title": "▶️ Enregistrer (auto)",
    "subtitle": "Démarrer pour la réunion en cours ou prochaine",
    "arg": "taskflowmac://start",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "stop",
    "title": "⏹ Arrêter",
    "subtitle": "Arrêter l'enregistrement",
    "arg": "taskflowmac://stop",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "pausetoggle",
    "title": "⏸ Pause / Resume",
    "subtitle": "Basculer pause/reprise",
    "arg": "taskflowmac://pausetoggle",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "cancel",
    "title": "❌ Annuler",
    "subtitle": "Annuler et supprimer l'enregistrement",
    "arg": "taskflowmac://cancel",
    "icon": {"path": "icon.png"}
  },
  {
    "uid": "status",
    "title": "📊 Status",
    "subtitle": "Afficher l'état actuel (debug log)",
    "arg": "taskflowmac://status",
    "icon": {"path": "icon.png"}
  }
]}
EOF
```

3. Connecte à une action **Open URL** avec `{query}` comme URL

## URL Schemes disponibles

| Scheme | Action |
|--------|--------|
| `taskflowmac://record` | Enregistrement libre (sans événement) |
| `taskflowmac://start` | Enregistrement auto (réunion en cours/prochaine) |
| `taskflowmac://stop` | Arrêter l'enregistrement |
| `taskflowmac://toggle` | Toggle start/stop |
| `taskflowmac://pause` | Mettre en pause |
| `taskflowmac://resume` | Reprendre |
| `taskflowmac://pausetoggle` | Toggle pause/resume |
| `taskflowmac://cancel` | Annuler l'enregistrement |
| `taskflowmac://assign?id=X` | Assigner l'événement X au fichier en attente |
| `taskflowmac://meetings` | Écrire le JSON des meetings dans /tmp |
| `taskflowmac://status` | Log l'état actuel (debug) |

## Alternative : Terminal

```bash
open "taskflowmac://record"   # Début
open "taskflowmac://stop"     # Fin
open "taskflowmac://cancel"   # Annuler
```
