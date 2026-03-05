//
//  URLSchemeHandler.swift
//  TaskFlowMac
//
//  Gère les URL schemes pour piloter l'app depuis Alfred/raccourcis clavier.
//
//  URL Schemes supportés :
//    taskflowmac://record       → démarre un enregistrement libre (sans événement)
//    taskflowmac://start        → démarre pour la réunion en cours/prochaine (mode auto)
//    taskflowmac://stop         → arrête l'enregistrement
//                                  - si événement associé → upload direct
//                                  - sinon → passe en mode picking
//    taskflowmac://toggle       → record si idle, stop si recording
//    taskflowmac://pause        → met en pause l'enregistrement
//    taskflowmac://resume       → reprend l'enregistrement
//    taskflowmac://pausetoggle  → pause si recording, resume si paused
//    taskflowmac://cancel       → annule l'enregistrement en cours
//    taskflowmac://assign?id=X  → assigne l'événement X au fichier en attente (picking)
//    taskflowmac://meetings     → écrit le JSON des réunions dans un fichier tmp (pour Alfred)
//    taskflowmac://status       → log l'état actuel (debug)
//
//  Utilisation avec Alfred :
//    Keyword "dr" → Open URL: taskflowmac://record
//    Keyword "fr" → Script Filter qui appelle taskflowmac://meetings + affiche la liste
//    Sélection dans Alfred → Open URL: taskflowmac://assign?id={query}
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
        case "record":
            startFreeRecording()
        case "start":
            startAutoRecording()
        case "stop":
            stopRecording()
        case "toggle":
            if appState.isRecording {
                stopRecording()
            } else {
                startFreeRecording()
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
        case "assign":
            assignEvent(from: url)
        case "meetings":
            writeMeetingsJSON()
        case "status":
            printStatus()
        default:
            print("\u{1f399}\u{fe0f} Unknown URL command: \(command)")
        }
    }
    
    // MARK: - Recording
    
    /// Démarre un enregistrement libre (sans événement)
    private func startFreeRecording() {
        guard !appState.isRecording else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Déjà en cours d'enregistrement")
            return
        }
        
        appState.startRecording()
        print("\u{1f399}\u{fe0f} \u{2705} Enregistrement libre démarré")
    }
    
    /// Démarre un enregistrement associé à la réunion en cours/prochaine
    private func startAutoRecording() {
        guard let event = appState.ongoingMeeting ?? appState.nextMeeting else {
            print("\u{1f399}\u{fe0f} \u{274c} Pas de réunion trouvée → enregistrement libre")
            startFreeRecording()
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
        print("\u{1f399}\u{fe0f} \u{23f9} Enregistrement arrêté")
    }
    
    private func pauseRecording() {
        guard appState.recordingPhase == .recording else { return }
        appState.pauseRecording()
    }
    
    private func resumeRecording() {
        guard appState.recordingPhase == .paused else { return }
        appState.resumeRecording()
    }
    
    private func cancelRecording() {
        if appState.isRecording {
            appState.cancelRecording()
        } else if appState.isPicking {
            appState.cancelPicking()
        }
    }
    
    // MARK: - Assign Event (picking)
    
    /// Assigne un événement au fichier en attente via URL scheme
    /// URL: taskflowmac://assign?id=NOTION_PAGE_ID
    private func assignEvent(from url: URL) {
        guard appState.recordingPhase == .picking else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} assign appelé hors phase picking")
            return
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let eventId = components.queryItems?.first(where: { $0.name == "id" })?.value else {
            print("\u{1f399}\u{fe0f} \u{274c} assign: paramètre id manquant")
            return
        }
        
        guard let event = appState.meetings.first(where: { $0.id == eventId }) else {
            print("\u{1f399}\u{fe0f} \u{274c} assign: événement \(eventId) non trouvé")
            return
        }
        
        appState.assignEvent(event)
        print("\u{1f399}\u{fe0f} \u{2705} Enregistrement assigné à: \(event.displayTitle)")
    }
    
    // MARK: - Meetings JSON (pour Alfred Script Filter)
    
    /// Écrit le JSON des réunions du jour dans un fichier temporaire
    /// Alfred peut le lire ensuite pour afficher la liste
    private func writeMeetingsJSON() {
        let json = appState.meetingsJSON
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskflowmac-meetings.json")
        try? json.write(to: tmpFile, atomically: true, encoding: .utf8)
        print("\u{1f399}\u{fe0f} \u{1f4cb} Meetings JSON écrit: \(tmpFile.path)")
    }
    
    // MARK: - Status
    
    private func printStatus() {
        print("\u{1f399}\u{fe0f} 📊 État: \(appState.recordingPhase)")
        print("\u{1f399}\u{fe0f} 📊 Réunion: \(appState.recordingEvent?.displayTitle ?? "aucune (libre)")")
        print("\u{1f399}\u{fe0f} 📊 Durée: \(appState.formattedDuration)")
        print("\u{1f399}\u{fe0f} 📊 Meetings: \(appState.meetings.count)")
        print("\u{1f399}\u{fe0f} 📊 Audio finalisé: \(appState.finalizedAudioURL?.lastPathComponent ?? "aucun")")
    }
}

extension View {
    func handleURLScheme() -> some View {
        modifier(URLSchemeModifier())
    }
}
