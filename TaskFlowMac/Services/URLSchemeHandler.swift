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
//    taskflowmac://cancel  → annule l'enregistrement en cours
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
        print("\u{1f399}\u{fe0f} URL Scheme: \(command)")
        
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
        case "cancel":
            cancelRecording()
        default:
            print("\u{1f399}\u{fe0f} Unknown URL command: \(command)")
        }
    }
    
    private func startRecording() {
        // Déterminer quelle réunion enregistrer : en cours > prochaine
        guard let event = appState.ongoingMeeting ?? appState.nextMeeting else {
            print("\u{1f399}\u{fe0f} \u{274c} Pas de réunion trouvée")
            return
        }
        
        guard !appState.isRecording else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Déjà en cours d'enregistrement")
            return
        }
        
        // Démarre la capture audio réelle via ScreenCaptureKit
        appState.startRecording(for: event)
        print("\u{1f399}\u{fe0f} \u{2705} Enregistrement démarré pour: \(event.displayTitle)")
    }
    
    private func stopRecording() {
        guard appState.isRecording else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Pas d'enregistrement en cours")
            return
        }
        
        // Arrête la capture + upload vers n8n
        appState.stopRecording()
        print("\u{1f399}\u{fe0f} \u{23f9} Enregistrement arrêté → upload en cours")
    }
    
    private func cancelRecording() {
        guard appState.isRecording else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Pas d'enregistrement en cours")
            return
        }
        
        appState.cancelRecording()
        print("\u{1f399}\u{fe0f} \u{1f5d1}\u{fe0f} Enregistrement annulé")
    }
}

extension View {
    func handleURLScheme() -> some View {
        modifier(URLSchemeModifier())
    }
}
