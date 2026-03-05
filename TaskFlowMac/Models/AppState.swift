//
//  AppState.swift
//  TaskFlowMac
//
//  État global de l'application.
//  Source de vérité unique pour les réunions et l'enregistrement.
//
//  Fonctionnalités :
//    - Sync des réunions du jour (cache local)
//    - Enregistrement audio micro avec pause/resume
//    - Persistance de l'état d'enregistrement (survie crash/quit)
//    - Auto-recovery au relancement (retry upload si fichier présent)
//    - Nettoyage automatique des fichiers orphelins > 48h
//

import SwiftUI
import Observation

@Observable
class AppState {
    
    // MARK: - Calendar
    
    /// Réunions du jour (depuis /taskflow-sync)
    var meetings: [CalendarEvent] = [] {
        didSet { saveCacheToDisk() }
    }
    
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
    
    init() {
        // Restore cache on launch
        lastSyncDate = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([CalendarEvent].self, from: data) {
            if Calendar.current.isDateInToday(lastSyncDate ?? .distantPast) {
                meetings = cached
            }
        }
    }
    
    private func saveCacheToDisk() {
        if let data = try? JSONEncoder().encode(meetings) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
    
    // MARK: - Recording State
    
    /// Phase d'enregistrement
    var recordingPhase: RecordingPhase = .idle
    
    /// Réunion en cours d'enregistrement
    var recordingEvent: CalendarEvent?
    
    /// Secondes écoulées (enregistrement effectif, sans les pauses)
    var elapsedSeconds: Int = 0
    
    /// Timer pour le compteur
    private var timer: Timer?
    
    /// Service de capture audio
    private let audioCaptureService = AudioCaptureService()
    
    /// Service d'upload vers n8n
    private let uploadService = UploadService()
    
    /// URL du fichier audio en cours d'enregistrement
    private var currentRecordingURL: URL?
    
    /// Date de démarrage de l'enregistrement (ISO8601)
    private var recordingStartDate: String?
    
    // MARK: - Computed
    
    var isRecording: Bool {
        switch recordingPhase {
        case .recording, .paused: return true
        default: return false
        }
    }
    
    /// Réunion en cours (now entre start et end)
    var ongoingMeeting: CalendarEvent? {
        let now = Date()
        return meetings.last { event in
            guard let start = event.startDate else { return false }
            let end = event.endDate ?? start.addingTimeInterval(3600)
            return now >= start && now < end
        }
    }
    
    /// Prochaine réunion
    var nextMeeting: CalendarEvent? {
        let now = Date()
        return meetings.first { event in
            guard let start = event.startDate else { return false }
            return start > now
        }
    }
    
    /// Durée formatée
    var formattedDuration: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
    
    // MARK: - Recording Actions
    
    /// Démarre la capture audio micro
    func startRecording(for event: CalendarEvent) {
        recordingEvent = event
        recordingPhase = .recording
        elapsedSeconds = 0
        recordingStartDate = ISO8601DateFormatter().string(from: Date())
        startTimer()
        
        // Persister l'état pour recovery
        persistRecordingState(event: event)
        
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.startCapture()
                currentRecordingURL = fileURL
                // Persister le chemin du fichier audio
                UserDefaults.standard.set(fileURL.path, forKey: "recording.audioFilePath")
                print("🎙️ ✅ Capture démarrée → \(fileURL.lastPathComponent)")
            } catch {
                print("🎙️ ❌ Erreur démarrage capture: \(error.localizedDescription)")
                recordingPhase = .error(error.localizedDescription)
                stopTimer()
                clearPersistedState()
            }
        }
    }
    
    /// Met en pause l'enregistrement
    func pauseRecording() {
        guard recordingPhase == .recording else { return }
        audioCaptureService.pauseCapture()
        recordingPhase = .paused
        stopTimer()
        print("🎙️ ⏸ Enregistrement en pause")
    }
    
    /// Reprend l'enregistrement après pause
    func resumeRecording() {
        guard recordingPhase == .paused else { return }
        do {
            try audioCaptureService.resumeCapture()
            recordingPhase = .recording
            startTimer()
            print("🎙️ ▶️ Enregistrement repris")
        } catch {
            print("🎙️ ❌ Erreur reprise: \(error.localizedDescription)")
            recordingPhase = .error(error.localizedDescription)
        }
    }
    
    /// Arrête la capture et lance l'upload vers n8n
    func stopRecording() {
        recordingPhase = .uploading
        stopTimer()
        
        guard let event = recordingEvent else {
            markError("Pas de réunion associée")
            return
        }
        
        // Persister la date de fin d'enregistrement et les participants pour recovery
        let recordingEndDate = ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set(recordingEndDate, forKey: "recording.endDate")
        if let participants = event.allParticipants ?? event.participants,
           let jsonData = try? JSONEncoder().encode(participants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            UserDefaults.standard.set(jsonString, forKey: "recording.participantsJSON")
        }
        
        Task { @MainActor in
            do {
                // 1. Arrêter la capture → fichier M4A finalisé
                let fileURL = try await audioCaptureService.stopCapture()
                print("🎙️ ✅ Fichier audio prêt: \(fileURL.lastPathComponent)")
                
                // 2. Upload vers n8n (avec retry 3x)
                // startDate = début d'enregistrement, endDate = maintenant (fin d'enregistrement)
                let startDate = self.recordingStartDate ?? ISO8601DateFormatter().string(from: Date())
                let endDate = ISO8601DateFormatter().string(from: Date())
                try await uploadService.uploadAudio(fileURL: fileURL, event: event, recordingStartDate: startDate, recordingEndDate: endDate)
                print("🎙️ ✅ Upload réussi")
                
                // 3. Cleanup : fichier + état persisté
                uploadService.cleanupFile(at: fileURL)
                currentRecordingURL = nil
                clearPersistedState()
                
                // 4. Marquer comme terminé
                markDone()
                
            } catch let captureError as AudioCaptureError {
                print("🎙️ ⚠️ Erreur capture: \(captureError.localizedDescription)")
                markError(captureError.localizedDescription ?? "Erreur de capture audio")
                // Ne pas clear l'état persisté — le fichier sera récupéré au relancement
            } catch {
                print("🎙️ ❌ Erreur stop/upload: \(error.localizedDescription)")
                markError(error.localizedDescription)
                // État persisté conservé pour retry au relancement
            }
        }
    }
    
    func markDone() {
        recordingPhase = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reset()
        }
    }
    
    func markError(_ message: String) {
        recordingPhase = .error(message)
    }
    
    func reset() {
        recordingPhase = .idle
        recordingEvent = nil
        elapsedSeconds = 0
        currentRecordingURL = nil
        recordingStartDate = nil
        stopTimer()
    }
    
    /// Annule l'enregistrement en cours
    func cancelRecording() {
        stopTimer()
        Task { @MainActor in
            await audioCaptureService.cancelCapture()
            clearPersistedState()
            reset()
        }
    }
    
    // MARK: - Persistence (UserDefaults) pour recovery après crash/quit
    
    private static let kEventId = "recording.eventId"
    private static let kEventTitle = "recording.eventTitle"
    private static let kNotionPageId = "recording.notionPageId"
    private static let kAudioFilePath = "recording.audioFilePath"
    private static let kStartDate = "recording.startDate"
    private static let kEndDate = "recording.endDate"
    private static let kParticipantsJSON = "recording.participantsJSON"
    private static let kIsActive = "recording.isActive"
    
    /// Persiste l'état d'enregistrement
    private func persistRecordingState(event: CalendarEvent) {
        let defaults = UserDefaults.standard
        defaults.set(event.id, forKey: Self.kEventId)
        defaults.set(event.displayTitle, forKey: Self.kEventTitle)
        defaults.set(event.notionPageId, forKey: Self.kNotionPageId)
        defaults.set(recordingStartDate, forKey: Self.kStartDate)
        defaults.set(true, forKey: Self.kIsActive)
        print("🎙️ 💾 État enregistrement persisté (event: \(event.displayTitle))")
    }
    
    /// Supprime l'état persisté
    func clearPersistedState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.kEventId)
        defaults.removeObject(forKey: Self.kEventTitle)
        defaults.removeObject(forKey: Self.kNotionPageId)
        defaults.removeObject(forKey: Self.kAudioFilePath)
        defaults.removeObject(forKey: Self.kStartDate)
        defaults.removeObject(forKey: Self.kEndDate)
        defaults.removeObject(forKey: Self.kParticipantsJSON)
        defaults.removeObject(forKey: Self.kIsActive)
    }
    
    /// Données récupérées d'un enregistrement interrompu
    struct RecoveredRecording {
        let eventTitle: String
        let notionPageId: String
        let audioFilePath: String
        let startDate: String
        let endDate: String
        let participantsJSON: String
    }
    
    /// Vérifie si un enregistrement interrompu peut être récupéré
    func checkForRecovery() -> RecoveredRecording? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.kIsActive),
              let eventTitle = defaults.string(forKey: Self.kEventTitle),
              let notionPageId = defaults.string(forKey: Self.kNotionPageId),
              let audioFilePath = defaults.string(forKey: Self.kAudioFilePath),
              let startDate = defaults.string(forKey: Self.kStartDate) else {
            return nil
        }
        
        let endDate = defaults.string(forKey: Self.kEndDate) ?? ISO8601DateFormatter().string(from: Date())
        let participantsJSON = defaults.string(forKey: Self.kParticipantsJSON) ?? "[]"
        
        // Vérifier que le fichier audio existe encore
        guard FileManager.default.fileExists(atPath: audioFilePath) else {
            print("🎙️ ⚠️ Fichier audio disparu: \(audioFilePath)")
            clearPersistedState()
            return nil
        }
        
        // Vérifier que le fichier n'est pas trop petit (> 10 KB)
        let size = (try? FileManager.default.attributesOfItem(atPath: audioFilePath)[.size] as? Int) ?? 0
        guard size > 10_240 else {
            try? FileManager.default.removeItem(atPath: audioFilePath)
            clearPersistedState()
            return nil
        }
        
        let sizeMB = Double(size) / 1_048_576
        print("🎙️ 🔄 Enregistrement récupérable trouvé: \(eventTitle) (\(String(format: "%.1f", sizeMB)) MB)")
        return RecoveredRecording(
            eventTitle: eventTitle,
            notionPageId: notionPageId,
            audioFilePath: audioFilePath,
            startDate: startDate,
            endDate: endDate,
            participantsJSON: participantsJSON
        )
    }
    
    /// Tente l'upload d'un enregistrement récupéré
    func retryRecoveredRecording(_ recovered: RecoveredRecording) {
        recordingPhase = .uploading
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let eventDate = dateFormatter.string(from: Date())
        
        Task { @MainActor in
            do {
                let fileURL = URL(fileURLWithPath: recovered.audioFilePath)
                try await uploadService.uploadRecoveredAudio(
                    fileURL: fileURL,
                    eventTitle: recovered.eventTitle,
                    notionPageId: recovered.notionPageId,
                    eventDate: eventDate,
                    startDate: recovered.startDate,
                    endDate: recovered.endDate,
                    participantsJSON: recovered.participantsJSON
                )
                
                // Succès → cleanup
                uploadService.cleanupFile(at: fileURL)
                clearPersistedState()
                print("🎙️ ✅ Recovery upload réussi pour: \(recovered.eventTitle)")
                markDone()
                
            } catch {
                print("🎙️ ❌ Recovery upload échoué: \(error.localizedDescription)")
                // L'état persisté reste — on réessaiera au prochain lancement
                markError("Upload échoué : \(recovered.eventTitle). Sera réessayé au prochain lancement.")
            }
        }
    }
    
    /// Supprime un enregistrement récupéré (choix utilisateur)
    func discardRecoveredRecording(_ recovered: RecoveredRecording) {
        try? FileManager.default.removeItem(atPath: recovered.audioFilePath)
        clearPersistedState()
        print("🎙️ 🗑️ Enregistrement récupéré supprimé: \(recovered.eventTitle)")
    }
    
    // MARK: - Timer
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.recordingPhase == .recording else { return }
            self.elapsedSeconds += 1
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Recording Phase

enum RecordingPhase: Equatable {
    case idle
    case recording
    case paused
    case uploading
    case done
    case error(String)
    
    static func == (lhs: RecordingPhase, rhs: RecordingPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.paused, .paused),
             (.uploading, .uploading), (.done, .done):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
