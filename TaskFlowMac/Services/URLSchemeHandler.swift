//
//  URLSchemeHandler.swift
//  TaskFlowMac
//
//  Gère les URL schemes pour piloter l'app depuis Alfred/raccourcis clavier.
//
//  URL Schemes supportés :
//    taskflowmac://start   → démarre l'enregistrement (réunion en cours ou prochaine)
//    taskflowmac://stop    → arrête l'enregistrement et lance la transcription
//    taskflowmac://toggle  → start si idle, stop si recording
//    taskflowmac://status  → (futur) retourne l'état
//
//  Utilisation avec Alfred :
//    Créer un workflow avec un Hotkey trigger → Open URL action
//    URL : taskflowmac://toggle
//    Ou en Terminal : open "taskflowmac://toggle"
//

import SwiftUI

struct URLSchemeModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    
    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                handleURL(url)
            }
    }
    
    private func handleURL(_ url: URL) {
        guard url.scheme == Config.urlScheme else { return }
        
        let command = url.host ?? ""
        print("🎙️ URL Scheme: \(command)")
        
        switch command {
        case "start":
            startRecording()
        case "stop":
            stopRecording()
        case "toggle":
            if appState.isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        default:
            print("🎙️ Unknown URL command: \(command)")
        }
    }
    
    private func startRecording() {
        // Déterminer quelle réunion enregistrer : en cours > prochaine
        guard let event = appState.ongoingMeeting ?? appState.nextMeeting else {
            print("🎙️ ❌ Pas de réunion trouvée")
            return
        }
        
        guard !appState.isRecording else {
            print("🎙️ ⚠️ Déjà en cours d'enregistrement")
            return
        }
        
        // TODO Phase 2 : démarrer ScreenCaptureKit ici
        appState.startRecording(for: event)
        print("🎙️ ✅ Enregistrement démarré pour: \(event.displayTitle)")
    }
    
    private func stopRecording() {
        guard appState.isRecording else {
            print("🎙️ ⚠️ Pas d'enregistrement en cours")
            return
        }
        
        // TODO Phase 2 : arrêter ScreenCaptureKit + upload
        appState.stopRecording()
        print("🎙️ ⏹ Enregistrement arrêté")
        
        // Simuler succès pour l'instant
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            appState.markDone()
        }
    }
}

extension View {
    func handleURLScheme() -> some View {
        modifier(URLSchemeModifier())
    }
}
