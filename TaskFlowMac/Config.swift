//
//  Config.swift
//  TaskFlowMac
//
//  Configuration centralisée.
//

import Foundation

enum Config {
    /// Base URL du serveur n8n
    static let n8nBaseURL = "https://n8n.clementziza.com/webhook"
    
    /// Endpoint sync (calendrier + tâches)
    static let syncURL = "\(n8nBaseURL)/taskflow-sync"
    
    /// Endpoint transcription (upload audio)
    static let transcribeURL = "\(n8nBaseURL)/taskflow-transcribe"
    
    /// Intervalle minimum entre deux syncs (secondes)
    static let minSyncInterval: TimeInterval = 60
    
    /// URL Scheme pour pilotage externe (Alfred, raccourcis clavier)
    static let urlScheme = "taskflowmac"
    
    /// Dossier de stockage des enregistrements temporaires
    static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("TaskFlowMacRecordings", isDirectory: true)
    }
}
