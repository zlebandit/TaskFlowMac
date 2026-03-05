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
    var meetings: [CalendarEvent] = []
    
    /// Dernière sync
    var lastSyncDate: Date?
    
    /// Chargement en cours
    var isLoading = false
    
    // MARK: - Recording
    
    /// Phase d'enregistrement
    var recordingPhase: RecordingPhase = .idle
    
    /// Réunion en cours d'enregistrement
    var recordingEvent: CalendarEvent?
    
    /// Secondes écoulées
    var elapsedSeconds: Int = 0
    
    /// Timer pour le compteur
    private var timer: Timer?
    
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
    
    func startRecording(for event: CalendarEvent) {
        recordingEvent = event
        recordingPhase = .recording
        elapsedSeconds = 0
        startTimer()
    }
    
    func stopRecording() {
        recordingPhase = .uploading
        stopTimer()
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
        stopTimer()
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
