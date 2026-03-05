//
//  SettingsView.swift
//  TaskFlowMac
//
//  Fenêtre de réglages (accès via Settings dans le menu).
//  Pour l'instant minimaliste : juste les infos et permissions.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Form {
            Section("G\u{00e9}n\u{00e9}ral") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Serveur", value: Config.n8nBaseURL)
            }
            
            Section("Raccourcis") {
                Text("Utilisez Alfred ou un autre launcher pour d\u{00e9}clencher :")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                LabeledContent("D\u{00e9}marrer") {
                    Text("open taskflowmac://start")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                
                LabeledContent("Arr\u{00ea}ter") {
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
                Text("L'enregistrement audio syst\u{00e8}me n\u{00e9}cessite l'autorisation \"Enregistrement de l'\u{00e9}cran\" dans Pr\u{00e9}f\u{00e9}rences Syst\u{00e8}me > Confidentialit\u{00e9}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button("Ouvrir les pr\u{00e9}f\u{00e9}rences") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 350)
    }
}
