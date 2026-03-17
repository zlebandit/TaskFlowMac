//
//  SettingsView.swift
//  TaskFlowMac
//
//  Fenêtre de réglages (accès via Settings dans le menu).
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    
    var body: some View {
        Form {
            Section("Général") {
                Toggle("Lancer au démarrage du Mac", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("SMAppService error: \(error)")
                            // Revert toggle si erreur
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Serveur", value: Config.n8nBaseURL)
            }
            
            Section("Raccourcis") {
                Text("Utilisez Alfred ou un autre launcher pour déclencher :")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                LabeledContent("Démarrer") {
                    Text("open taskflowmac://start")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                
                LabeledContent("Arrêter") {
                    Text("open taskflowmac://stop")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                
                LabeledContent("Toggle") {
                    Text("open taskflowmac://toggle")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            
            Section("Permissions") {
                Text("L'enregistrement audio nécessite l'autorisation \"Microphone\" dans Réglages Système > Confidentialité & sécurité.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button("Ouvrir les réglages") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
    }
}
