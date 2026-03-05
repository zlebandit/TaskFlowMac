# TaskFlowMac

App macOS MenuBar pour afficher les réunions du jour et enregistrer/transcrire automatiquement l'audio des visioconférences.

## Architecture

- **Type** : macOS MenuBarExtra (.window style), pas d'icône Dock (LSUIElement)
- **Swift** : SwiftUI + Observation framework (@Observable)
- **Cible** : macOS 14+ (Sonoma)
- **Repo GitHub** : `zlebandit/TaskFlowMac` (public)
- **VPS** : `/vps/taskflow-mac/`
- **Mac local** : `~/Documents/Ressources/TaskFlowMac/`

## État actuel — Phase 1 ✅

### Ce qui fonctionne
- Icône menubar (waveform) → popover avec liste des réunions du jour
- Sync via webhook n8n `https://n8n.clementziza.com/webhook/taskflow-sync`
- Cache UserDefaults (affichage immédiat du cache, sync en arrière-plan)
- Format date français ("Jeudi 5 mars", "1er" pour le premier du mois)
- Titres et lieux multi-lignes
- Barre colorée : jaune (pro) / rose (perso)
- Bouton micro sur chaque réunion (UI seulement, pas de capture réelle)
- Bandeau REC en haut quand enregistrement simulé
- URL Scheme : `taskflowmac://start`, `taskflowmac://stop`, `taskflowmac://toggle`
- Raccourci ⌘⇧R (affiché en footer)
- Bouton Quitter en footer
- Pas d'icône dans le Dock (LSUIElement = true dans Info.plist)
- App Sandbox + Outgoing Connections (Client) activés via entitlements

### Fichiers Swift
```
TaskFlowMac/
├── TaskFlowMacApp.swift          # @main, MenuBarExtra + Settings scene
├── Config.swift                   # syncURL, minSyncInterval
├── Info.plist                     # URL scheme + LSUIElement
├── Models/
│   ├── AppState.swift             # @Observable, meetings, recording state, cache UserDefaults
│   └── CalendarEvent.swift        # Codable model (Titre, DateStart, DateEnd, Lieu, Calendrier, participants...)
├── Services/
│   ├── SyncService.swift          # POST vers webhook, decode SyncResponse { calendar: [CalendarEvent] }
│   └── URLSchemeHandler.swift     # .onOpenURL handler pour taskflowmac://
└── Views/
    ├── MenuBarPopover.swift       # Vue principale : header date, liste réunions, footer
    └── SettingsView.swift         # Fenêtre Settings (placeholder)
```

## Phase 2 — À faire 🚧

### Objectif
Capture audio système (Teams/Zoom/Meet) via ScreenCaptureKit + transcription automatique via n8n/Whisper.

### Flux cible
1. Clic sur 🎤 (ou URL scheme `taskflowmac://start`) → démarre capture audio système via ScreenCaptureKit
2. Clic sur ⏹ (ou `taskflowmac://stop`) → arrête capture, sauvegarde fichier audio (M4A)
3. Upload multipart du fichier audio vers n8n workflow `lLIDlf1W4H1qNDeq` (TaskFlow Transcription Réunion)
4. n8n envoie à Whisper/OpenAI pour transcription → stocke dans Notion

### Défis techniques
- **ScreenCaptureKit** : `SCStream` avec `SCStreamConfiguration.capturesAudio = true`
- **Permission TCC** : macOS demandera l'autorisation Screen Recording
- **Audio système** (pas micro) : capturer l'audio des apps de visio
- **Encodage** : AVAssetWriter pour écrire le buffer audio en fichier M4A
- **Upload** : multipart/form-data POST vers n8n avec le fichier + metadata (notionPageId, titre)
- **Entitlements** : peut nécessiter `com.apple.security.temporary-exception.audio-unit-host` ou désactiver sandbox pour audio

### Service à créer
- `AudioCaptureService.swift` : gère SCStream, AVAssetWriter, start/stop
- Modifier `AppState.swift` : brancher le vrai recording au lieu du simulé
- Modifier `SyncService.swift` ou créer `UploadService.swift` : upload multipart vers n8n

## Workflows n8n

| Workflow | ID | Usage |
|----------|-----|-------|
| TaskFlow Sync | `YtcNU48S2wQczCGl` | Récupère les réunions du jour |
| TaskFlow Sync Get Réunions | `QlSisY6lXxWpwNWB` | Sub-workflow appelé par le sync |
| TaskFlow Transcription Réunion | `lLIDlf1W4H1qNDeq` | Reçoit l'audio, transcrit, stocke dans Notion |

## Connexions MCP disponibles

- `mcpServer_vps_admin` — VPS Admin (file_read, file_write, file_patch, git_push, shell_exec...)
- `mcpServer_github` — GitHub API
- `mcpServer_n8n_mcp` — n8n documentation
- `mcpServer_context7` — Context7 (documentation libs)

## Infos utiles

- **Git token** : déjà configuré dans le remote origin du repo
- **User** : Bruno Clément-Ziza, bclementziza@gmail.com
- **Xcode** : le projet est configuré localement, git pull + ⌘R pour tester
- **Entitlements** : créés via Signing & Capabilities (App Sandbox + Outgoing Connections)
- **Info.plist** : référencé dans Build Settings > Packaging > Info.plist File = `TaskFlowMac/Info.plist`
