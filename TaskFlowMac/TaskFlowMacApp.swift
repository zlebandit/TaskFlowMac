//
//  TaskFlowMacApp.swift
//  TaskFlowMac
//
//  Mini app menubar pour transcription automatique de réunions.
//  Capture le micro du Mac (réunions en salle) via AVAudioEngine.
//
//  Pilotage via URL Scheme (géré par NSAppleEventManager dans URLSchemeHandler) :
//    taskflowmac://record  → enregistrement libre
//    taskflowmac://start   → enregistrement auto (réunion en cours/prochaine)
//    taskflowmac://stop    → arrête l'enregistrement
//    taskflowmac://toggle  → start/stop automatique
//    taskflowmac://pause   → met en pause
//    taskflowmac://resume  → reprend
//    taskflowmac://cancel  → annule
//    taskflowmac://assign?id=X → assigne un événement après stop
//    taskflowmac://meetings → écrit le JSON des réunions (pour Alfred)
//
//  Au lancement :
//    - Nettoyage des fichiers audio orphelins > 48h
//    - Auto-recovery d'un enregistrement interrompu (crash/quit)
//      → une seule fois, jamais pendant un enregistrement actif
//

import SwiftUI

/// AppDelegate pour enregistrer le URL Scheme handler dès le lancement
/// (NSAppleEventManager doit être configuré avant le premier événement)
class AppDelegate: NSObject, NSApplicationDelegate {
    var urlSchemeHandler: URLSchemeHandler?
    
    func setup(appState: AppState) {
        urlSchemeHandler = URLSchemeHandler(appState: appState)
    }
}

@main
struct TaskFlowMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    
    /// Flag pour ne vérifier la recovery qu'une seule fois
    @State private var hasCheckedRecovery = false
    
    init() {
        // Nettoyage des fichiers orphelins > 48h au lancement
        AudioCaptureService.cleanupOrphanedRecordings()
    }
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environment(appState)
                .onAppear {
                    // Configurer le URL scheme handler au premier affichage
                    if appDelegate.urlSchemeHandler == nil {
                        appDelegate.setup(appState: appState)
                    }
                    // Recovery : une seule fois
                    checkForRecoveredRecordingOnce()
                }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
        
        // Invisible Settings window (pour les permissions)
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
    
    // MARK: - MenuBar Icon
    
    /// Icône dynamique
    private var menuBarLabel: some View {
        Group {
            switch appState.recordingPhase {
            case .recording:
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .red)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.orange, .orange)
            case .uploading:
                Image(systemName: "arrow.up.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.blue, .blue)
            case .picking:
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.green, .green)
            default:
                Image(systemName: "waveform")
            }
        }
    }
    
    // MARK: - Recovery (une seule fois)
    
    private func checkForRecoveredRecordingOnce() {
        guard !hasCheckedRecovery else { return }
        hasCheckedRecovery = true
        
        guard let recovered = appState.checkForRecovery() else { return }
        
        print("🎙️ 🔄 Enregistrement récupéré trouvé: \(recovered.eventTitle)")
        appState.retryRecoveredRecording(recovered)
    }
}
