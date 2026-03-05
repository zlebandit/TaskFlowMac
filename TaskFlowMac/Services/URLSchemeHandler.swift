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
//    taskflowmac://pause   → met en pause l'enregistrement
//    taskflowmac://resume  → reprend l'enregistrement après pause
//    taskflowmac://pausetoggle → pause si recording, resume si paused
//    taskflowmac://cancel  → annule l'enregistrement en cours
//    taskflowmac://status  → log l'état actuel (debug)
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
        case "pause":
            pauseRecording()
        case "resume":
            resumeRecording()
        case "pausetoggle":
            if appState.recordingPhase == .paused {
                resumeRecording()
            } else if appState.recordingPhase == .recording {
                pauseRecording()
            }
        case "cancel":
            cancelRecording()
        case "status":
            printStatus()
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
        
        appState.startRecording(for: event)
        print("\u{1f399}\u{fe0f} \u{2705} Enregistrement démarré pour: \(event.displayTitle)")
    }
    
    private func stopRecording() {
        guard appState.isRecording else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Pas d'enregistrement en cours")
            return
        }
        
        appState.stopRecording()
        print("\u{1f399}\u{fe0f} \u{23f9} Enregistrement arrêté → upload en cours")
    }
    
    private func pauseRecording() {
        guard appState.recordingPhase == .recording else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Pas en cours d'enregistrement actif")
            return
        }
        
        appState.pauseRecording()
        print("\u{1f399}\u{fe0f} \u{23f8} Enregistrement en pause")
    }
    
    private func resumeRecording() {
        guard appState.recordingPhase == .paused else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} L'enregistrement n'est pas en pause")
            return
        }
        
        appState.resumeRecording()
        print("\u{1f399}\u{fe0f} \u{25b6}\u{fe0f} Enregistrement repris")
    }
    
    private func cancelRecording() {
        guard appState.isRecording else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Pas d'enregistrement en cours")
            return
        }
        
        appState.cancelRecording()
        print("\u{1f399}\u{fe0f} \u{1f5d1}\u{fe0f} Enregistrement annulé")
    }
    
    private func printStatus() {
        print("\u{1f399}\u{fe0f} 📊 État: \(appState.recordingPhase)")
        print("\u{1f399}\u{fe0f} 📊 Réunion: \(appState.recordingEvent?.displayTitle ?? "aucune")")
        print("\u{1f399}\u{fe0f} 📊 Durée: \(appState.formattedDuration)")
        print("\u{1f399}\u{fe0f} 📊 Meetings: \(appState.meetings.count)")
    }
}

extension View {
    func handleURLScheme() -> some View {
        modifier(URLSchemeModifier())
    }
}
