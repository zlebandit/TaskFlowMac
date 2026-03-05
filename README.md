# 🎙️ TaskFlowMac

Mini app macOS menubar pour transcription automatique de réunions (Teams, Zoom, Meet).
Capture l'audio système via ScreenCaptureKit et envoie à Gemini pour générer un compte-rendu dans Notion.

## ✨ Fonctionnalités

- **Icône menubar** avec popover affichant les réunions du jour
- **Enregistrement audio système** (capture Teams/Zoom/Meet via ScreenCaptureKit)
- **Pilotage via URL Scheme** pour raccourcis clavier Alfred :
  - `taskflowmac://start` — démarre l'enregistrement
  - `taskflowmac://stop` — arrête et envoie pour transcription
  - `taskflowmac://toggle` — start/stop automatique
- **Même pipeline que TaskFlow iPhone** : upload vers n8n → Gemini 3 Flash → CR Notion
- **Pas d'icône dans le Dock** (LSUIElement = true)

## 🎮 Utilisation avec Alfred

Créer un workflow Alfred avec :
1. **Hotkey** trigger (ex: `⌘⇧R`)
2. **Open URL** action : `taskflowmac://toggle`

Ou en Terminal :
```bash
open "taskflowmac://start"   # Démarrer
open "taskflowmac://stop"    # Arrêter
open "taskflowmac://toggle"  # Toggle
```

## 🏗 Architecture

```
TaskFlowMac/
├── TaskFlowMacApp.swift       # @main + MenuBarExtra
├── Config.swift               # URLs webhooks, constantes
├── Info.plist                 # URL Scheme + LSUIElement
├── Models/
│   ├── AppState.swift         # @Observable, état global (meetings + recording)
│   └── CalendarEvent.swift    # Modèle événement + Participant
├── Services/
│   ├── SyncService.swift      # Appel /taskflow-sync (calendrier du jour)
│   └── URLSchemeHandler.swift  # Gère taskflowmac:// pour Alfred
└── Views/
    ├── MenuBarPopover.swift   # Popover principal (meetings + recording controls)
    └── SettingsView.swift     # Fenêtre réglages (permissions, raccourcis)
```

## 📋 Phases de développement

### ✅ Phase 1 — Squelette menubar + calendrier
- [x] MenuBarExtra SwiftUI avec popover
- [x] Appel /taskflow-sync pour les réunions du jour
- [x] URL Scheme pour pilotage Alfred
- [x] Modèles CalendarEvent / Participant
- [x] Info.plist (URL Scheme + LSUIElement)

### 🟡 Phase 2 — Capture audio système
- [ ] ScreenCaptureKit : capture audio uniquement (pas vidéo)
- [ ] Conversion PCM → AAC (AVAudioConverter)
- [ ] Gestion permissions "Enregistrement de l'écran"
- [ ] Stockage temporaire dans Documents/

### 🟡 Phase 3 — Upload + pipeline
- [ ] TranscriptionService (upload multipart vers /taskflow-transcribe)
- [ ] Mêmes metadata que l'iPhone (eventTitle, notionPageId, participants, etc.)
- [ ] Retry avec backoff

### 🟡 Phase 4 — Polish
- [ ] Auto-start au login (SMAppService)
- [ ] Notifications macOS natives
- [ ] Raccourci clavier global natif (en plus d'Alfred)
- [ ] Détection automatique des calls en cours

## 🚀 Setup

1. Cloner le repo
2. Ouvrir dans Xcode (File > Open > sélectionner le dossier TaskFlowMac)
3. Créer un nouveau projet Xcode macOS App (SwiftUI, target macOS 14+)
4. Ajouter les fichiers Swift du dossier TaskFlowMac/
5. Build & Run

## 🔗 Backend

Réutilise exactement le même pipeline n8n que TaskFlow iPhone :
- `/taskflow-sync` — réunions du jour
- `/taskflow-transcribe` — upload audio + transcription Gemini + CR Notion

Zéro changement côté serveur.
