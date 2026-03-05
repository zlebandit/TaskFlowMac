//
//  AppState.swift
//  TaskFlowMac
//
//  État global de l'application.
//  Source de vérité unique pour les réunions et l'enregistrement.
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
            // Only restore if cache is from today
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
    
    // MARK: - Recording
    
    /// Phase d'enregistrement
    var recordingPhase: RecordingPhase = .idle
    
    /// Réunion en cours d'enregistrement
    var recordingEvent: CalendarEvent?
    
    /// Secondes écoulées
    var elapsedSeconds: Int = 0
    
    /// Timer pour le compteur
    private var timer: Timer?
    
    /// Service de capture audio (ScreenCaptureKit)
    private let audioCaptureService = AudioCaptureService()
    
    /// Service d'upload vers n8n
    private let uploadService = UploadService()
    
    /// URL du fichier audio en cours d'enregistrement
    private var currentRecordingURL: URL?
    
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
    
    // MARK: - Actions
    
    /// Démarre la capture audio réelle via ScreenCaptureKit
    func startRecording(for event: CalendarEvent) {
        recordingEvent = event
        recordingPhase = .recording
        elapsedSeconds = 0
        startTimer()
        
        // Lancer la capture audio en arrière-plan
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.startCapture()
                currentRecordingURL = fileURL
                print("🎙️ ✅ Capture démarrée → \(fileURL.lastPathComponent)")
            } catch {
                print("🎙️ ❌ Erreur démarrage capture: \(error.localizedDescription)")
                recordingPhase = .error(error.localizedDescription)
                stopTimer()
            }
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
        
        // Arrêter la capture + upload en arrière-plan
        Task { @MainActor in
            do {
                // 1. Arrêter la capture → fichier M4A finalisé
                let fileURL = try await audioCaptureService.stopCapture()
                print("🎙️ ✅ Fichier audio prêt: \(fileURL.lastPathComponent)")
                
                // 2. Upload vers n8n pour transcription
                try await uploadService.uploadAudio(fileURL: fileURL, event: event)
                print("🎙️ ✅ Upload réussi")
                
                // 3. Cleanup du fichier local
                uploadService.cleanupFile(at: fileURL)
                currentRecordingURL = nil
                
                // 4. Marquer comme terminé
                markDone()
                
            } catch is AudioCaptureError {
                // Erreur de capture (noAudioCaptured, permissionDenied, etc.)
                print("🎙️ ⚠️ Erreur capture: \(error.localizedDescription)")
                markError(error.localizedDescription)
            } catch {
                print("🎙️ ❌ Erreur stop/upload: \(error.localizedDescription)")
                markError(error.localizedDescription)
            }
        }
    }
    
    func markDone() {
        recordingPhase = .done
        // Reset après 3s
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
        stopTimer()
    }
    
    /// Annule l'enregistrement en cours
    func cancelRecording() {
        stopTimer()
        Task { @MainActor in
            await audioCaptureService.cancelCapture()
            reset()
        }
    }
    
    // MARK: - Timer
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsedSeconds += 1
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
