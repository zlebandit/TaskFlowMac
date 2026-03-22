//
//  AppState.swift
//  TaskFlowMac
//
//  Orchestrateur principal de l'application.
//  Responsabilités :
//    - Calendrier : sync des réunions, cache, JSON Alfred
//    - Délégation à RecordingManager pour tout ce qui concerne l'audio
//
//  Les vues accèdent à l'enregistrement via les propriétés/méthodes forwards
//  de cette classe (aucun changement nécessaire dans les vues).
//

import SwiftUI
import Observation

@Observable
class AppState {
    
    // MARK: - Calendar
    
    /// Réunions du jour (depuis /taskflow-sync)
    var meetings: [CalendarEvent] = []
    
    /// Dernière sync
    var lastSyncDate: Date? {
        didSet {
            if let d = lastSyncDate {
                UserDefaults.standard.set(d, forKey: "lastSyncDate")
            }
        }
    }
    
    /// Chargement en cours
    var isLoading = false
    
    // MARK: - Cache
    
    private static let cacheKey = "cachedMeetings"
    
    /// Chemin fixe du JSON des meetings pour Alfred
    static var meetingsJSONPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".taskflowmac-meetings.json").path
    }
    
    // MARK: - Recording (délégué à RecordingManager)
    
    let recording = RecordingManager()
    
    /// Typealias pour backward compatibility (ex: checkForRecovery)
    typealias RecoveredRecording = RecordingManager.RecoveredRecording
    
    // MARK: - Init
    
    init() {
        lastSyncDate = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([CalendarEvent].self, from: data) {
            if Calendar.current.isDateInToday(lastSyncDate ?? .distantPast) {
                meetings = cached
            }
        }
        writeMeetingsJSONFile()
    }
    
    // MARK: - Cache
    
    func saveCacheToDisk() {
        if let data = try? JSONEncoder().encode(meetings) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
    
    /// Écrit le JSON des meetings au format Alfred Script Filter dans un fichier fixe
    func writeMeetingsJSONFile() {
        let path = Self.meetingsJSONPath
        let json = meetingsJSON
        print("[AppState] writeMeetingsJSONFile: \(meetings.count) meetings")
        do {
            try json.write(toFile: path, atomically: true, encoding: .utf8)
            print("[AppState] JSON écrit: \(path)")
        } catch {
            print("[AppState] Erreur écriture JSON: \(error)")
        }
    }
    
    // MARK: - Sync
    
    func syncMeetings() async {
        if let lastSync = lastSyncDate,
           Date().timeIntervalSince(lastSync) < Config.minSyncInterval {
            return
        }
        await forceSyncMeetings()
    }
    
    func forceSyncMeetings() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let fetched = try await SyncService().fetchMeetings()
            meetings = fetched
            saveCacheToDisk()
            writeMeetingsJSONFile()
            lastSyncDate = Date()
            print("[AppState] Sync: \(fetched.count) réunions")
        } catch {
            print("[AppState] Sync failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Computed (calendrier)
    
    var ongoingMeeting: CalendarEvent? {
        let now = Date()
        return meetings.last { event in
            guard let start = event.startDate else { return false }
            let end = event.endDate ?? start.addingTimeInterval(3600)
            return now >= start && now < end
        }
    }
    
    var nextMeeting: CalendarEvent? {
        let now = Date()
        return meetings.first { event in
            guard let start = event.startDate else { return false }
            return start > now
        }
    }
    
    // MARK: - Alfred JSON (Codable)
    
    private struct AlfredResult: Encodable {
        let items: [AlfredItem]
    }
    
    private struct AlfredItem: Encodable {
        let uid: String
        let title: String
        let subtitle: String
        let arg: String
        let icon: AlfredIcon
    }
    
    private struct AlfredIcon: Encodable {
        let path: String
    }
    
    var meetingsJSON: String {
        let items = meetings.map { event in
            AlfredItem(
                uid: event.id,
                title: event.displayTitle,
                subtitle: event.timeRange + (event.Lieu.map { " \u{2014} \($0)" } ?? ""),
                arg: event.id,
                icon: AlfredIcon(path: "icon.png")
            )
        }
        let result = AlfredResult(items: items)
        guard let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"items\": []}"
        }
        return json
    }
    
    // MARK: - Recording Forwarding
    //
    // Les propriétés et méthodes ci-dessous délèguent à RecordingManager.
    // Elles existent pour que MenuBarPopover, TaskFlowMacApp et URLSchemeHandler
    // n'aient pas à être modifiés.
    
    var recordingPhase: RecordingPhase         { recording.recordingPhase }
    var recordingEvent: CalendarEvent?          { recording.recordingEvent }
    var elapsedSeconds: Int                     { recording.elapsedSeconds }
    var finalizedAudioURL: URL?                 { recording.finalizedAudioURL }
    var pendingUploads: [PendingUploadInfo]      { recording.pendingUploads }
    var isRetryingPendingUpload: Bool            { recording.isRetryingPendingUpload }
    var uploadProgress: Double                    { recording.uploadProgress }
    var audioLevel: Float                        { recording.audioLevel }
    var isRecording: Bool                        { recording.isRecording }
    var isPicking: Bool                          { recording.isPicking }
    var formattedDuration: String               { recording.formattedDuration }
    
    func startRecording(for event: CalendarEvent? = nil) { recording.startRecording(for: event) }
    func pauseRecording()                                { recording.pauseRecording() }
    func resumeRecording()                               { recording.resumeRecording() }
    func stopRecording()                                 { recording.stopRecording() }
    func stopAndAssign(_ event: CalendarEvent)           { recording.stopAndAssign(event) }
    func assignEvent(_ event: CalendarEvent)             { recording.assignEvent(event) }
    func cancelPicking()                                 { recording.cancelPicking() }
    func reset()                                         { recording.reset() }
    func cancelRecording()                               { recording.cancelRecording() }
    func scanPendingUploads()                            { recording.scanPendingUploads() }
    func assignPendingUpload(_ p: PendingUploadInfo)     { recording.assignPendingUpload(p) }
    func retryPendingUpload(_ p: PendingUploadInfo)      { recording.retryPendingUpload(p) }
    func discardPendingUpload(_ p: PendingUploadInfo)    { recording.discardPendingUpload(p) }
    func initializePendingUploads()                      { recording.initializePendingUploads() }
    func clearPersistedState()                           { recording.clearPersistedState() }
    
    func checkForRecovery() -> RecoveredRecording?               { recording.checkForRecovery() }
    func retryRecoveredRecording(_ r: RecoveredRecording)        { recording.retryRecoveredRecording(r) }
    func discardRecoveredRecording(_ r: RecoveredRecording)      { recording.discardRecoveredRecording(r) }
}
