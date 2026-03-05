//
//  TaskFlowMacApp.swift
//  TaskFlowMac
//
//  Mini app menubar pour transcription automatique de réunions.
//  Capture le micro du Mac (réunions en salle) via AVAudioEngine.
//
//  Pilotage via URL Scheme :
//    taskflowmac://start   → démarre l'enregistrement du prochain RDV
//    taskflowmac://stop    → arrête et envoie pour transcription
//    taskflowmac://pause   → met en pause l'enregistrement
//    taskflowmac://resume  → reprend l'enregistrement
//    taskflowmac://toggle  → start/stop automatique
//    taskflowmac://cancel  → annule l'enregistrement
//
//  Au lancement :
//    - Nettoyage des fichiers audio orphelins > 48h
//    - Auto-recovery d'un enregistrement interrompu (crash/quit)
//      → une seule fois, jamais pendant un enregistrement actif
//

import SwiftUI

@main
struct TaskFlowMacApp: App {
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
                    // Recovery : une seule fois au tout premier affichage du popover
                    // + jamais si un enregistrement est déjà actif
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
    
    /// Icône dynamique : micro normal, pulsant rouge si enregistrement, pause si en pause
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
            default:
                Image(systemName: "waveform")
            }
        }
    }
    
    // MARK: - Recovery (une seule fois)
    
    /// Vérifie une seule fois si un enregistrement interrompu peut être récupéré.
    /// Ne fait rien si déjà vérifié, ou si un enregistrement est actif.
    private func checkForRecoveredRecordingOnce() {
        guard !hasCheckedRecovery else { return }
        hasCheckedRecovery = true
        
        guard let recovered = appState.checkForRecovery() else { return }
        
        print("🎙️ 🔄 Enregistrement récupéré trouvé: \(recovered.eventTitle)")
        
        // Auto-retry silencieux
        appState.retryRecoveredRecording(recovered)
    }
}
