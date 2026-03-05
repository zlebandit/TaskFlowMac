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
- **Boutons UI** : pause ⏸ / resume ▶️ / stop ⏹ / annuler ✕ dans le popover
- **Indicateurs visuels** : badge PAUSE orange, badge REC rouge, icône menubar contextuelle

## URL Schemes

Pilotage depuis Alfred, Terminal, ou raccourcis clavier :

| Commande | URL | Description |
|----------|-----|-------------|
| Start | `taskflowmac://start` | Démarre l'enregistrement (réunion en cours > prochaine) |
| Stop | `taskflowmac://stop` | Arrête et envoie pour transcription |
| Toggle | `taskflowmac://toggle` | Start si idle, Stop si recording |
| Pause | `taskflowmac://pause` | Met en pause l'enregistrement |
| Resume | `taskflowmac://resume` | Reprend après pause |
| Pause Toggle | `taskflowmac://pausetoggle` | Pause si recording, Resume si paused |
| Cancel | `taskflowmac://cancel` | Annule l'enregistrement (supprime le fichier) |
| Status | `taskflowmac://status` | Log l'état actuel (debug) |

### Utilisation en Terminal
```bash
open "taskflowmac://toggle"        # Démarre ou arrête
open "taskflowmac://pausetoggle"   # Pause ou reprend
open "taskflowmac://cancel"        # Annule
```

## Intégration Alfred

Un workflow Alfred est fourni dans `alfred/TaskFlowMac.alfredworkflow`.

**Raccourcis configurés :**
- `⌘⇧R` → Toggle enregistrement (start/stop)
- `⌘⇧P` → Toggle pause (pause/resume)
- `⌘⇧X` → Annuler l'enregistrement
- Keyword `tf` → Liste des commandes TaskFlowMac

## Fichiers Swift

```
TaskFlowMac/
├── TaskFlowMacApp.swift          # @main, MenuBarExtra + recovery au lancement + cleanup orphelins
├── Config.swift                   # syncURL, transcribeURL, recordingsDirectory, urlScheme
├── Info.plist                     # URL scheme + LSUIElement + NSMicrophoneUsageDescription
├── TaskFlowMac.entitlements       # App Sandbox + Outgoing Connections + Microphone
├── Models/
│   ├── AppState.swift             # État global : meetings, recording, pause/resume, persistance, recovery
│   └── CalendarEvent.swift        # Codable model (Titre, DateStart, DateEnd, Lieu, participants...)
├── Services/
│   ├── AudioCaptureService.swift  # AVAudioEngine + AVAssetWriter → micro → M4A (pause/resume, cleanup)
│   ├── UploadService.swift        # Upload multipart streaming + retry 3x backoff + recovery upload
│   ├── SyncService.swift          # Fetch réunions du jour via webhook n8n
│   └── URLSchemeHandler.swift     # Handler URL schemes (start/stop/toggle/pause/resume/cancel/status)
└── Views/
    ├── MenuBarPopover.swift       # Vue principale : banners, boutons pause/resume/cancel/stop, liste réunions
    └── SettingsView.swift         # Fenêtre Settings (placeholder)
```

## Flux d'enregistrement

```
1. Clic 🎤 ou taskflowmac://start
   └─→ AVAudioEngine démarre le tap micro
   └─→ AVAssetWriter encode en M4A (AAC 128kbps)
   └─→ État persisté dans UserDefaults

2. (Optionnel) taskflowmac://pause / resume
   └─→ Engine en pause, buffers ignorés
   └─→ Timestamps ajustés (pas de silence dans le fichier)

3. Clic ⏹ ou taskflowmac://stop
   └─→ Finalise le fichier M4A
   └─→ Upload multipart vers n8n (retry 3x)
   └─→ Cleanup fichier local + état persisté

4. Si crash/quit pendant enregistrement :
   └─→ Au relancement : détecte fichier + état persisté
   └─→ Auto-retry upload silencieux
   └─→ Fichiers orphelins > 48h nettoyés automatiquement
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
5. Installer le workflow Alfred depuis `alfred/TaskFlowMac.alfredworkflow`

## Connexions MCP disponibles

- `mcpServer_vps_admin` — VPS Admin (file_read, file_write, git_push, shell_exec...)
- `mcpServer_github` — GitHub API
- `mcpServer_n8n_mcp` — n8n documentation
- `mcpServer_context7` — Context7 (documentation libs)
