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
- URL Scheme : `taskflowmac://start`, `taskflowmac://stop`, `taskflowmac://toggle`, `taskflowmac://cancel`
- Raccourci ⌘⇧R (affiché en footer)
- Bouton Quitter en footer
- Pas d'icône dans le Dock (LSUIElement = true dans Info.plist)
- App Sandbox + Outgoing Connections (Client) activés via entitlements

## État actuel — Phase 2 🚧 (en cours)

### Capture audio système + transcription automatique

#### Flux implémenté
1. **Clic sur 🎤** (ou URL scheme `taskflowmac://start`) → démarre capture audio système via **ScreenCaptureKit**
2. **Clic sur ⏹** (ou `taskflowmac://stop`) → arrête la capture, sauvegarde fichier M4A via **AVAssetWriter**
3. **Upload multipart** du fichier audio vers n8n workflow `lLIDlf1W4H1qNDeq` (TaskFlow Transcription Réunion)
4. **n8n** envoie à Whisper/OpenAI pour transcription → stocke dans Notion

#### Nouveaux fichiers créés
- `Services/AudioCaptureService.swift` — Capture audio système via ScreenCaptureKit + encodage M4A
- `Services/UploadService.swift` — Upload multipart/form-data vers n8n avec metadata

#### Fichiers modifiés
- `Models/AppState.swift` — Intègre AudioCaptureService + UploadService (vrais services au lieu de simulations)
- `Services/URLSchemeHandler.swift` — Ajout commande `cancel`, retrait des simulations
- `Views/MenuBarPopover.swift` — Bannières done/error, bouton annuler, état uploading
- `Info.plist` — Ajout `NSScreenCaptureUsageDescription` pour permission Screen Recording

#### Détails techniques
- **ScreenCaptureKit** : `SCStream` avec `SCStreamConfiguration.capturesAudio = true`
- **Audio** : 44.1kHz stéréo, AAC 128kbps, format M4A
- **Vidéo** : config minimale (2x2px, 1fps) — obligatoire mais inutilisé
- **Permission TCC** : macOS demandera l'autorisation Screen Recording au premier lancement
- **Upload** : multipart/form-data avec champs `file`, `notionPageId`, `titre`, `source`, `duree`
- **Fichiers temp** : stockés dans `~/Documents/TaskFlowMacRecordings/`, nettoyés après upload

#### ⚠️ À faire côté Xcode (Bruno)
- `git pull` pour récupérer les modifications
- **Add Files to Project** pour les nouveaux fichiers : `AudioCaptureService.swift`, `UploadService.swift`
- Vérifier que le **Signing & Capabilities** a bien App Sandbox + Outgoing Connections
- **Build & test** : au premier lancement, macOS demandera la permission Screen Recording
- Si nécessaire : aller dans Préférences Système > Confidentialité > Enregistrement de l'écran pour autoriser TaskFlowMac

### Fichiers Swift
```
TaskFlowMac/
├── TaskFlowMacApp.swift          # @main, MenuBarExtra + Settings scene
├── Config.swift                   # syncURL, transcribeURL, recordingsDirectory
├── Info.plist                     # URL scheme + LSUIElement + NSScreenCaptureUsageDescription
├── Models/
│   ├── AppState.swift             # @Observable, meetings, recording state, AudioCaptureService, UploadService
│   └── CalendarEvent.swift        # Codable model (Titre, DateStart, DateEnd, Lieu, Calendrier, participants...)
├── Services/
│   ├── AudioCaptureService.swift  # ScreenCaptureKit + AVAssetWriter → capture audio système → M4A
│   ├── UploadService.swift        # Upload multipart/form-data vers n8n (fichier + metadata)
│   ├── SyncService.swift          # POST vers webhook, decode SyncResponse { calendar: [CalendarEvent] }
│   └── URLSchemeHandler.swift     # .onOpenURL handler pour taskflowmac:// (start/stop/toggle/cancel)
└── Views/
    ├── MenuBarPopover.swift       # Vue principale : header date, recording/done/error banners, liste réunions, footer
    └── SettingsView.swift         # Fenêtre Settings (placeholder)
```

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
