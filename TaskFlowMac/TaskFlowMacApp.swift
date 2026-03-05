//
//  TaskFlowMacApp.swift
//  TaskFlowMac
//
//  Mini app menubar pour transcription automatique de réunions.
//  Capture l'audio système (Teams/Zoom/Meet) via ScreenCaptureKit.
//
//  Pilotage via URL Scheme :
//    taskflowmac://start   → démarre l'enregistrement du prochain RDV
//    taskflowmac://stop    → arrête et envoie pour transcription
//    taskflowmac://toggle  → start/stop automatique
//

import SwiftUI

@main
struct TaskFlowMacApp: App {
    @State private var appState = AppState()
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environment(appState)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
        
        // Invisible Settings window (pour les permissions ScreenCaptureKit)
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
    
    // MARK: - MenuBar Icon
    
    /// Icône dynamique : micro normal ou pulsant rouge si enregistrement
    private var menuBarLabel: some View {
        Group {
            if appState.isRecording {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .red)
            } else {
                Image(systemName: "waveform")
            }
        }
    }
}
