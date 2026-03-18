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
//    - Enregistrement du URL Scheme handler (dès le .task, avant tout événement Alfred)
//    - Sync des réunions du jour (pour que Alfred ait les meetings immédiatement)
//    - Nettoyage des fichiers audio orphelins > 48h (protège les sidecars)
//    - Migration UserDefaults → sidecar JSON (one-shot)
//    - Auto-retry des fichiers assignés en attente d'upload
//    - Recovery d'un enregistrement interrompu (crash/quit)
//

import SwiftUI

/// AppDelegate pour enregistrer le URL Scheme handler dès le lancement
/// (NSAppleEventManager doit être configuré avant le premier événement)
class AppDelegate: NSObject, NSApplicationDelegate {
    var urlSchemeHandler: URLSchemeHandler?
    
    func setup(appState: AppState) {
        guard urlSchemeHandler == nil else { return }
        urlSchemeHandler = URLSchemeHandler(appState: appState)
    }
}

@main
struct TaskFlowMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    
    init() {
        // Nettoyage des fichiers orphelins > 48h au lancement
        // (protège les fichiers avec sidecar JSON)
        AudioCaptureService.cleanupOrphanedRecordings()
    }
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environment(appState)
                .onAppear {
                    // Scanner les fichiers en attente d'upload à chaque ouverture
                    appState.scanPendingUploads()
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
        .task {
            // 1. URL Scheme handler (doit être enregistré avant tout événement Alfred)
            appDelegate.setup(appState: appState)
            // 2. Migration + scan + auto-retry des pending uploads
            appState.initializePendingUploads()
            // 3. Sync des réunions du jour (pour que Alfred ait des meetings dès le lancement)
            await appState.syncMeetings()
            // 4. Timer de sync périodique en arrière-plan (toutes les 3 min)
            //    Permet de détecter les réunions créées dans Notion sans ouvrir le popover
            startPeriodicSync()
        }
    }
    
    // MARK: - Periodic Sync
    
    /// Lance un timer qui rafraîchit les réunions toutes les 3 minutes,
    /// même si le popover est fermé. Garantit que le JSON Alfred et
    /// appState.meetings restent à jour pour les commandes dr/fr.
    private func startPeriodicSync() {
        Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            Task { await appState.syncMeetings() }
        }
    }
}
