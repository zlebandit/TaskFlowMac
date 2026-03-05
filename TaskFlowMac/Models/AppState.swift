//
//  AppState.swift
//  TaskFlowMac
//
//  État global de l'application.
//  Source de vérité unique pour les réunions et l'enregistrement.
//
//  Flux d'enregistrement :
//    1. startRecording() ou startRecording(for:) → capture micro
//    2. (optionnel) pauseRecording() / resumeRecording()
//    3. stopRecording() → arrête la capture, passe en .picking
//    4. assignEvent(_:) → associe un événement et upload vers n8n
//       OU cancelPicking() → annule et supprime le fichier
//
//  Deux modes de démarrage :
//    - Libre (sans événement) : dr / bouton 🎙 en haut du popover
//    - Associé à un événement : clic 🍤 sur une réunion spécifique
//      (dans ce cas, stopRecording() upload directement sans phase picking)
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
    
    init() {
        // Restore cache on launch
        lastSyncDate = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([CalendarEvent].self, from: data) {
            if Calendar.current.isDateInToday(lastSyncDate ?? .distantPast) {
                meetings = cached
            }
        }
        // Écrire le JSON pour Alfred au lancement (didSet ne se déclenche pas dans init)
        writeMeetingsJSONFile()
    }
    
    func saveCacheToDisk() {
        if let data = try? JSONEncoder().encode(meetings) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
    
    /// Écrit le JSON des meetings au format Alfred Script Filter dans un fichier fixe
    /// Ce fichier est lu par le script Alfred "fr" pour afficher la liste des réunions
    func writeMeetingsJSONFile() {
        let path = Self.meetingsJSONPath
        let json = meetingsJSON
        print("\u{1f399}\u{fe0f} \u{1f4dd} writeMeetingsJSONFile: \(meetings.count) meetings, path=\(path)")
        do {
            try json.write(toFile: path, atomically: true, encoding: .utf8)
            print("\u{1f399}\u{fe0f} \u{2705} JSON \u00e9crit: \(path)")
        } catch {
            print("\u{1f399}\u{fe0f} \u{274c} Erreur \u00e9criture JSON: \(error)")
        }
    }
    
    // MARK: - Recording State
    
    /// Phase d'enregistrement
    var recordingPhase: RecordingPhase = .idle
    
    /// Réunion en cours d'enregistrement (nil si enregistrement libre)
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
    
    /// URL du fichier audio finalisé (après stop, en attente d'assignation)
    var finalizedAudioURL: URL?
    
    /// Date de démarrage de l'enregistrement (ISO8601)
    private var recordingStartDate: String?
    
    /// Date de fin de l'enregistrement (ISO8601)
    private var recordingEndDate: String?
    
    // MARK: - Computed
    
    var isRecording: Bool {
        switch recordingPhase {
        case .recording, .paused: return true
        default: return false
        }
    }
    
    /// Est-ce qu'on est en phase de sélection d'événement après stop ?
    var isPicking: Bool {
        recordingPhase == .picking
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
    
    /// JSON des réunions du jour au format Alfred Script Filter
    var meetingsJSON: String {
        let items = meetings.map { event -> [String: Any] in
            [
                "uid": event.id,
                "title": event.displayTitle,
                "subtitle": event.timeRange + (event.Lieu.map { " \u{2014} \($0)" } ?? ""),
                "arg": event.id,
                "icon": ["path": "icon.png"]
            ]
        }
        let result: [String: Any] = ["items": items]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"items\": []}"
        }
        return json
    }
    
    // MARK: - Recording Actions
    
    /// Démarre la capture audio micro SANS événement (enregistrement libre)
    func startRecording() {
        recordingEvent = nil
        recordingPhase = .recording
        elapsedSeconds = 0
        recordingStartDate = ISO8601DateFormatter().string(from: Date())
        recordingEndDate = nil
        finalizedAudioURL = nil
        startTimer()
        
        // Persister l'état pour recovery (sans événement)
        persistRecordingState(event: nil)
        
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.startCapture()
                currentRecordingURL = fileURL
                UserDefaults.standard.set(fileURL.path, forKey: "recording.audioFilePath")
                print("\u{1f399}\u{fe0f} \u{2705} Capture libre d\u{e9}marr\u{e9}e \u{2192} \(fileURL.lastPathComponent)")
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Erreur d\u{e9}marrage capture: \(error.localizedDescription)")
                recordingPhase = .error(error.localizedDescription)
                stopTimer()
                clearPersistedState()
            }
        }
    }
    
    /// Démarre la capture audio micro AVEC un événement (mode classique)
    func startRecording(for event: CalendarEvent) {
        recordingEvent = event
        recordingPhase = .recording
        elapsedSeconds = 0
        recordingStartDate = ISO8601DateFormatter().string(from: Date())
        recordingEndDate = nil
        finalizedAudioURL = nil
        startTimer()
        
        // Persister l'état pour recovery
        persistRecordingState(event: event)
        
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.startCapture()
                currentRecordingURL = fileURL
                UserDefaults.standard.set(fileURL.path, forKey: "recording.audioFilePath")
                print("\u{1f399}\u{fe0f} \u{2705} Capture d\u{e9}marr\u{e9}e pour \(event.displayTitle) \u{2192} \(fileURL.lastPathComponent)")
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Erreur d\u{e9}marrage capture: \(error.localizedDescription)")
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
        print("\u{1f399}\u{fe0f} \u{23f8} Enregistrement en pause")
    }
    
    /// Reprend l'enregistrement après pause
    func resumeRecording() {
        guard recordingPhase == .paused else { return }
        do {
            try audioCaptureService.resumeCapture()
            recordingPhase = .recording
            startTimer()
            print("\u{1f399}\u{fe0f} \u{25b6}\u{fe0f} Enregistrement repris")
        } catch {
            print("\u{1f399}\u{fe0f} \u{274c} Erreur reprise: \(error.localizedDescription)")
            recordingPhase = .error(error.localizedDescription)
        }
    }
    
    /// Arr\u{ea}te la capture.
    /// - Si un \u{e9}v\u{e9}nement est d\u{e9}j\u{e0} associ\u{e9} \u{2192} upload directement
    /// - Sinon \u{2192} passe en phase .picking (s\u{e9}lection d'\u{e9}v\u{e9}nement)
    func stopRecording() {
        stopTimer()
        recordingEndDate = ISO8601DateFormatter().string(from: Date())
        
        // Persister la date de fin pour recovery
        UserDefaults.standard.set(recordingEndDate, forKey: "recording.endDate")
        
        if let event = recordingEvent {
            // Mode classique : \u{e9}v\u{e9}nement d\u{e9}j\u{e0} associ\u{e9} \u{2192} upload direct
            recordingPhase = .uploading
            persistParticipants(event: event)
            finalizeAndUpload(event: event)
        } else {
            // Mode libre : finaliser le fichier et passer en picking
            recordingPhase = .uploading // temporaire pendant la finalisation
            Task { @MainActor in
                do {
                    let fileURL = try await audioCaptureService.stopCapture()
                    self.finalizedAudioURL = fileURL
                    self.recordingPhase = .picking
                    print("\u{1f399}\u{fe0f} \u{2705} Fichier audio pr\u{ea}t, en attente d'affectation: \(fileURL.lastPathComponent)")
                } catch {
                    print("\u{1f399}\u{fe0f} \u{274c} Erreur finalisation: \(error.localizedDescription)")
                    self.markError(error.localizedDescription)
                }
            }
        }
    }
    
    /// Stop + Assign en une seule commande (pour Alfred fr)
    /// Arr\u{ea}te l'enregistrement et assigne imm\u{e9}diatement l'\u{e9}v\u{e9}nement
    func stopAndAssign(_ event: CalendarEvent) {
        guard isRecording else {
            // Si d\u{e9}j\u{e0} en picking, juste assigner
            if recordingPhase == .picking {
                assignEvent(event)
            }
            return
        }
        
        stopTimer()
        recordingEndDate = ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set(recordingEndDate, forKey: "recording.endDate")
        
        // Assigner l'\u{e9}v\u{e9}nement et uploader directement
        recordingEvent = event
        recordingPhase = .uploading
        persistParticipants(event: event)
        persistRecordingState(event: event)
        finalizeAndUpload(event: event)
    }
    
    /// Assigne un \u{e9}v\u{e9}nement au fichier audio finalis\u{e9} et lance l'upload
    func assignEvent(_ event: CalendarEvent) {
        guard recordingPhase == .picking, let fileURL = finalizedAudioURL else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} assignEvent appel\u{e9} hors phase picking")
            return
        }
        
        recordingEvent = event
        recordingPhase = .uploading
        
        // Persister pour recovery
        persistRecordingState(event: event)
        UserDefaults.standard.set(fileURL.path, forKey: "recording.audioFilePath")
        persistParticipants(event: event)
        
        print("\u{1f399}\u{fe0f} \u{1f4ce} Enregistrement assign\u{e9} \u{e0}: \(event.displayTitle) \u{2192} upload...")
        uploadFinalizedFile(fileURL: fileURL, event: event)
    }
    
    /// Annule la phase de picking (supprime le fichier audio)
    func cancelPicking() {
        guard recordingPhase == .picking else { return }
        
        if let fileURL = finalizedAudioURL {
            uploadService.cleanupFile(at: fileURL)
        }
        clearPersistedState()
        reset()
        print("\u{1f399}\u{fe0f} \u{1f5d1}\u{fe0f} Enregistrement supprim\u{e9} (picking annul\u{e9})")
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
        finalizedAudioURL = nil
        recordingStartDate = nil
        recordingEndDate = nil
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
    
    // MARK: - Private Upload Helpers
    
    /// Finalise la capture et uploade directement (mode avec \u{e9}v\u{e9}nement pr\u{e9}-associ\u{e9})
    private func finalizeAndUpload(event: CalendarEvent) {
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.stopCapture()
                print("\u{1f399}\u{fe0f} \u{2705} Fichier audio pr\u{ea}t: \(fileURL.lastPathComponent)")
                
                let startDate = self.recordingStartDate ?? ISO8601DateFormatter().string(from: Date())
                let endDate = self.recordingEndDate ?? ISO8601DateFormatter().string(from: Date())
                try await uploadService.uploadAudio(fileURL: fileURL, event: event, recordingStartDate: startDate, recordingEndDate: endDate)
                print("\u{1f399}\u{fe0f} \u{2705} Upload r\u{e9}ussi")
                
                uploadService.cleanupFile(at: fileURL)
                currentRecordingURL = nil
                clearPersistedState()
                markDone()
                
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Erreur stop/upload: \(error.localizedDescription)")
                markError(error.localizedDescription)
            }
        }
    }
    
    /// Upload un fichier d\u{e9}j\u{e0} finalis\u{e9} (apr\u{e8}s assignation d'\u{e9}v\u{e9}nement)
    private func uploadFinalizedFile(fileURL: URL, event: CalendarEvent) {
        Task { @MainActor in
            do {
                let startDate = self.recordingStartDate ?? ISO8601DateFormatter().string(from: Date())
                let endDate = self.recordingEndDate ?? ISO8601DateFormatter().string(from: Date())
                try await uploadService.uploadAudio(fileURL: fileURL, event: event, recordingStartDate: startDate, recordingEndDate: endDate)
                print("\u{1f399}\u{fe0f} \u{2705} Upload r\u{e9}ussi pour: \(event.displayTitle)")
                
                uploadService.cleanupFile(at: fileURL)
                finalizedAudioURL = nil
                currentRecordingURL = nil
                clearPersistedState()
                markDone()
                
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Erreur upload: \(error.localizedDescription)")
                markError(error.localizedDescription)
            }
        }
    }
    
    /// Persiste les participants d'un \u{e9}v\u{e9}nement pour recovery
    private func persistParticipants(event: CalendarEvent) {
        if let participants = event.allParticipants ?? event.participants,
           let jsonData = try? JSONEncoder().encode(participants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            UserDefaults.standard.set(jsonString, forKey: "recording.participantsJSON")
        }
    }
    
    // MARK: - Persistence (UserDefaults) pour recovery apr\u{e8}s crash/quit
    
    private static let kEventId = "recording.eventId"
    private static let kEventTitle = "recording.eventTitle"
    private static let kNotionPageId = "recording.notionPageId"
    private static let kAudioFilePath = "recording.audioFilePath"
    private static let kStartDate = "recording.startDate"
    private static let kEndDate = "recording.endDate"
    private static let kParticipantsJSON = "recording.participantsJSON"
    private static let kIsActive = "recording.isActive"
    
    /// Persiste l'\u{e9}tat d'enregistrement
    private func persistRecordingState(event: CalendarEvent?) {
        let defaults = UserDefaults.standard
        defaults.set(event?.id ?? "free-recording", forKey: Self.kEventId)
        defaults.set(event?.displayTitle ?? "Enregistrement libre", forKey: Self.kEventTitle)
        defaults.set(event?.notionPageId ?? "", forKey: Self.kNotionPageId)
        defaults.set(recordingStartDate, forKey: Self.kStartDate)
        defaults.set(true, forKey: Self.kIsActive)
        print("\u{1f399}\u{fe0f} \u{1f4be} \u{c9}tat persist\u{e9} (event: \(event?.displayTitle ?? "libre"))")
    }
    
    /// Supprime l'\u{e9}tat persist\u{e9}
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
    
    /// Donn\u{e9}es r\u{e9}cup\u{e9}r\u{e9}es d'un enregistrement interrompu
    struct RecoveredRecording {
        let eventTitle: String
        let notionPageId: String
        let audioFilePath: String
        let startDate: String
        let endDate: String
        let participantsJSON: String
    }
    
    /// V\u{e9}rifie si un enregistrement interrompu peut \u{ea}tre r\u{e9}cup\u{e9}r\u{e9}.
    /// Ne retourne rien si un enregistrement est actuellement en cours.
    func checkForRecovery() -> RecoveredRecording? {
        // GUARD: ne pas interf\u{e9}rer avec un enregistrement actif ou un picking
        guard !isRecording, recordingPhase == .idle else {
            print("\u{1f399}\u{fe0f} \u{23ed} Recovery ignor\u{e9}e : enregistrement en cours")
            return nil
        }
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.kIsActive),
              let eventTitle = defaults.string(forKey: Self.kEventTitle),
              let audioFilePath = defaults.string(forKey: Self.kAudioFilePath),
              let startDate = defaults.string(forKey: Self.kStartDate) else {
            return nil
        }
        
        let notionPageId = defaults.string(forKey: Self.kNotionPageId) ?? ""
        let endDate = defaults.string(forKey: Self.kEndDate) ?? ISO8601DateFormatter().string(from: Date())
        let participantsJSON = defaults.string(forKey: Self.kParticipantsJSON) ?? "[]"
        
        // V\u{e9}rifier que le fichier audio existe encore
        guard FileManager.default.fileExists(atPath: audioFilePath) else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Fichier audio disparu: \(audioFilePath)")
            clearPersistedState()
            return nil
        }
        
        // V\u{e9}rifier que le fichier n'est pas trop petit (> 10 KB)
        let size = (try? FileManager.default.attributesOfItem(atPath: audioFilePath)[.size] as? Int) ?? 0
        guard size > 10_240 else {
            try? FileManager.default.removeItem(atPath: audioFilePath)
            clearPersistedState()
            return nil
        }
        
        let sizeMB = Double(size) / 1_048_576
        print("\u{1f399}\u{fe0f} \u{1f504} Enregistrement r\u{e9}cup\u{e9}rable trouv\u{e9}: \(eventTitle) (\(String(format: "%.1f", sizeMB)) MB)")
        
        // Si c'\u{e9}tait un enregistrement libre (pas encore assign\u{e9}), passer en picking
        if notionPageId.isEmpty {
            print("\u{1f399}\u{fe0f} \u{1f504} Enregistrement libre r\u{e9}cup\u{e9}r\u{e9} \u{2192} phase picking")
            finalizedAudioURL = URL(fileURLWithPath: audioFilePath)
            recordingStartDate = startDate
            recordingEndDate = endDate
            recordingPhase = .picking
            return nil // Pas de recovery auto \u{2014} l'utilisateur va choisir l'\u{e9}v\u{e9}nement
        }
        
        return RecoveredRecording(
            eventTitle: eventTitle,
            notionPageId: notionPageId,
            audioFilePath: audioFilePath,
            startDate: startDate,
            endDate: endDate,
            participantsJSON: participantsJSON
        )
    }
    
    /// Tente l'upload d'un enregistrement r\u{e9}cup\u{e9}r\u{e9}
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
                
                uploadService.cleanupFile(at: fileURL)
                clearPersistedState()
                print("\u{1f399}\u{fe0f} \u{2705} Recovery upload r\u{e9}ussi pour: \(recovered.eventTitle)")
                markDone()
                
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Recovery upload \u{e9}chou\u{e9}: \(error.localizedDescription)")
                markError("Upload \u{e9}chou\u{e9} : \(recovered.eventTitle). Sera r\u{e9}essay\u{e9} au prochain lancement.")
            }
        }
    }
    
    /// Supprime un enregistrement r\u{e9}cup\u{e9}r\u{e9} (choix utilisateur)
    func discardRecoveredRecording(_ recovered: RecoveredRecording) {
        try? FileManager.default.removeItem(atPath: recovered.audioFilePath)
        clearPersistedState()
        print("\u{1f399}\u{fe0f} \u{1f5d1}\u{fe0f} Enregistrement r\u{e9}cup\u{e9}r\u{e9} supprim\u{e9}: \(recovered.eventTitle)")
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
    case picking    // En attente de s\u{e9}lection d'\u{e9}v\u{e9}nement apr\u{e8}s stop
    case done
    case error(String)
    
    static func == (lhs: RecordingPhase, rhs: RecordingPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.paused, .paused),
             (.uploading, .uploading), (.picking, .picking), (.done, .done):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
