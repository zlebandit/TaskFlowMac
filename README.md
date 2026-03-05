# TaskFlowMac

App macOS MenuBar pour afficher les réunions du jour et enregistrer/transcrire automatiquement l'audio via le microphone du Mac.

## Architecture

- **Type** : macOS MenuBarExtra (.window style), pas d'icône Dock (LSUIElement)
- **Swift** : SwiftUI + Observation framework (@Observable)
- **Cible** : macOS 14+ (Sonoma)
- **Repo GitHub** : `zlebandit/TaskFlowMac` (public)
- **VPS** : `/vps/taskflow-mac/`
- **Mac local** : `~/Documents/Ressources/TaskFlowMac/`

## Fonctionnalités

### Phase 1 ✅ — Menu bar + réunions
- Icône menubar dynamique (waveform / rouge rec / orange pause / bleu upload)
- Popover avec liste des réunions du jour
- Sync via webhook n8n `https://n8n.clementziza.com/webhook/taskflow-sync`
- Cache UserDefaults (affichage immédiat, sync en arrière-plan)
- Format date français ("Jeudi 5 mars", "1er" pour le premier du mois)
- Titres et lieux multi-lignes
- Barre colorée : jaune (pro) / rose (perso)
- Bouton Quitter en footer
- Pas d'icône dans le Dock (LSUIElement = true)

### Phase 2 ✅ — Capture micro + transcription
- **Capture audio micro** via AVAudioEngine (réunions en salle)
- **Encodage M4A** (AAC 128kbps) via AVAssetWriter
- **Upload multipart** vers n8n pour transcription Gemini → Notion
- **Retry automatique** : 3 tentatives avec backoff exponentiel (2s → 5s → 10s)
- **Validation fichier** : taille min 10 KB, max 500 MB avant upload
- **Streaming upload** : fichier audio envoyé par chunks de 1 MB (pas tout en RAM)

### Phase 3 ✅ — Robustesse & pilotage
- **Pause / Resume** : met en pause l'enregistrement (l'audio pendant les pauses est ignoré)
- **Persistance état** : survie crash/quit via UserDefaults
- **Auto-recovery** : au relancement, détecte un enregistrement interrompu et retente l'upload
- **Nettoyage automatique** : fichiers orphelins > 48h supprimés au lancement
- **Indicateurs visuels** : badge PAUSE orange, badge REC rouge, icône menubar contextuelle

### Phase 4 ✅ — Enregistrement libre + Alfred dr/fr
- **Enregistrement libre** : démarrer sans affecter à une réunion (bouton 🎙 dans le popover ou `dr` dans Alfred)
- **Phase picking** : après l'arrêt d'un enregistrement libre, sélection de la réunion dans l'app ou via Alfred
- **Deux modes de démarrage** :
  - Libre (sans événement) → `taskflowmac://record` ou bouton 🎙
  - Associé à une réunion → clic 🎤 sur une réunion ou `taskflowmac://start`
- **Workflow Alfred dr/fr** :
  - `dr` (début de réunion) → lance un enregistrement libre
  - `fr` (fin de réunion) → stoppe, affiche la liste des réunions, sélection → upload
- **UX picking dans l'app** : écran dédié avec liste des réunions cliquables + bouton supprimer
- **Recovery intelligente** : les enregistrements libres interrompus passent en picking au relancement

## URL Schemes

Pilotage depuis Alfred, Terminal, ou raccourcis clavier :

| Commande | URL | Description |
|----------|-----|-------------|
| Record | `taskflowmac://record` | Enregistrement libre (sans événement) |
| Start | `taskflowmac://start` | Enregistrement auto (réunion en cours > prochaine) |
| Stop | `taskflowmac://stop` | Arrête l'enregistrement |
| Toggle | `taskflowmac://toggle` | Record si idle, Stop si recording |
| Pause | `taskflowmac://pause` | Met en pause l'enregistrement |
| Resume | `taskflowmac://resume` | Reprend après pause |
| Pause Toggle | `taskflowmac://pausetoggle` | Pause si recording, Resume si paused |
| Cancel | `taskflowmac://cancel` | Annule l'enregistrement (supprime le fichier) |
| Assign | `taskflowmac://assign?id=X` | Assigne l'événement X au fichier en attente |
| Meetings | `taskflowmac://meetings` | Écrit le JSON des meetings dans /tmp (pour Alfred) |
| Status | `taskflowmac://status` | Log l'état actuel (debug) |

### Utilisation en Terminal
```bash
open "taskflowmac://record"         # Enregistrement libre
open "taskflowmac://stop"           # Arrêter
open "taskflowmac://pausetoggle"    # Pause ou reprend
open "taskflowmac://cancel"         # Annuler
```

## Intégration Alfred

Voir `alfred/README.md` pour le guide complet.

**Flux recommandé :**
```
⌘Space → dr → Entrée → Enregistrement démarre
⌘Space → fr → Entrée → Stop → Liste réunions → Sélection → Upload
```

**Raccourcis optionnels :**
- `⌘⇧P` → Toggle pause/resume
- `⌘⇧X` → Annuler l'enregistrement

## Flux d'enregistrement

### Mode libre (dr / bouton 🎙)
```
1. dr dans Alfred ou bouton 🎙 dans le popover
   └─→ AVAudioEngine démarre le tap micro
   └─→ État persisté (event = nil)

2. (Optionnel) pause / resume

3. fr dans Alfred ou bouton ⏹ dans le popover
   └─→ Finalise le fichier M4A
   └─→ Phase "picking" : l'app affiche les réunions
   └─→ Sélection d'une réunion → upload vers n8n

4. Si crash pendant picking :
   └─→ Au relancement : fichier + état → retour en picking
```

### Mode associé (clic 🎤 sur une réunion)
```
1. Clic 🎤 sur une réunion
   └─→ AVAudioEngine démarre
   └─→ État persisté (event associé)

2. Stop → Upload direct (pas de picking)
```

## Fichiers Swift

```
TaskFlowMac/
├── TaskFlowMacApp.swift          # @main, MenuBarExtra + recovery au lancement + cleanup orphelins
├── Config.swift                   # syncURL, transcribeURL, recordingsDirectory, urlScheme
├── Info.plist                     # URL scheme + LSUIElement + NSMicrophoneUsageDescription
├── TaskFlowMac.entitlements       # App Sandbox + Outgoing Connections + Microphone
├── Models/
│   ├── AppState.swift             # État global : meetings, recording libre/associé, picking, recovery
│   └── CalendarEvent.swift        # Codable model (Titre, DateStart, DateEnd, Lieu, participants...)
├── Services/
│   ├── AudioCaptureService.swift  # AVAudioEngine + AVAssetWriter → micro → M4A (pause/resume, cleanup)
│   ├── UploadService.swift        # Upload multipart streaming + retry 3x backoff + recovery upload
│   ├── SyncService.swift          # Fetch réunions du jour via webhook n8n
│   └── URLSchemeHandler.swift     # Handler URL schemes (record/start/stop/assign/meetings/...)
└── Views/
    ├── MenuBarPopover.swift       # Vue principale : banners, bouton 🎙 libre, picking, liste réunions
    └── SettingsView.swift         # Fenêtre Settings (placeholder)
```

## Workflows n8n

| Workflow | ID | Usage |
|----------|-----|-------|
| TaskFlow Sync | `YtcNU48S2wQczCGl` | Récupère les réunions du jour |
| TaskFlow Sync Get Réunions | `QlSisY6lXxWpwNWB` | Sub-workflow appelé par le sync |
| TaskFlow Transcription Réunion | `lLIDlf1W4H1qNDeq` | Reçoit l'audio, transcrit via Gemini, stocke dans Notion |

## Permissions requises

- **Microphone** : NSMicrophoneUsageDescription (Info.plist) + com.apple.security.device.audio-input (entitlements)
- **Réseau** : com.apple.security.network.client (entitlements) pour les webhooks n8n
- **App Sandbox** : activé

## Setup Xcode (Bruno)

1. `git pull` pour récupérer les modifications
2. **Add Files to Project** si nouveaux fichiers Swift
3. Vérifier **Signing & Capabilities** : App Sandbox + Outgoing Connections
4. **Build & Run** (⌘R) — macOS demandera la permission Microphone au premier lancement
5. Configurer le workflow Alfred (voir `alfred/README.md`)

## Connexions MCP disponibles

- `mcpServer_vps_admin` — VPS Admin (file_read, file_write, git_push, shell_exec...)
- `mcpServer_github` — GitHub API
- `mcpServer_n8n_mcp` — n8n documentation
- `mcpServer_context7` — Context7 (documentation libs)
