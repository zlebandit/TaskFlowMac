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
//    - Associé à un événement : clic 🎤 sur une réunion spécifique
//      (dans ce cas, stopRecording() upload directement sans phase picking)
//

import SwiftUI
import Observation

@Observable
class AppState {
    
    // MARK: - Calendar
    
    /// Réunions du jour (depuis /taskflow-sync)
    var meetings: [CalendarEvent] = [] {
        didSet {
            saveCacheToDisk()
            writeMeetingsJSONFile()
        }
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
    }
    
    private func saveCacheToDisk() {
        if let data = try? JSONEncoder().encode(meetings) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
    
    /// Écrit le JSON des meetings au format Alfred Script Filter dans un fichier fixe
    /// Ce fichier est lu par le script Alfred "fr" pour afficher la liste des réunions
    private func writeMeetingsJSONFile() {
        let json = meetingsJSON
        let path = Self.meetingsJSONPath
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
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
                "subtitle": event.timeRange + (event.Lieu.map { " \u2014 \($0)" } ?? ""),
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
                print("🎙️ ✅ Capture libre démarrée → \(fileURL.lastPathComponent)")
            } catch {
                print("🎙️ ❌ Erreur démarrage capture: \(error.localizedDescription)")
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
                print("🎙️ ✅ Capture démarrée pour \(event.displayTitle) → \(fileURL.lastPathComponent)")
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
    
    /// Arrête la capture.
    /// - Si un événement est déjà associé → upload directement
    /// - Sinon → passe en phase .picking (sélection d'événement)
    func stopRecording() {
        stopTimer()
        recordingEndDate = ISO8601DateFormatter().string(from: Date())
        
        // Persister la date de fin pour recovery
        UserDefaults.standard.set(recordingEndDate, forKey: "recording.endDate")
        
        if let event = recordingEvent {
            // Mode classique : événement déjà associé → upload direct
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
                    print("🎙️ ✅ Fichier audio prêt, en attente d'affectation: \(fileURL.lastPathComponent)")
                } catch {
                    print("🎙️ ❌ Erreur finalisation: \(error.localizedDescription)")
                    self.markError(error.localizedDescription)
                }
            }
        }
    }
    
    /// Stop + Assign en une seule commande (pour Alfred fr)
    /// Arrête l'enregistrement et assigne immédiatement l'événement
    func stopAndAssign(_ event: CalendarEvent) {
        guard isRecording else {
            // Si déjà en picking, juste assigner
            if recordingPhase == .picking {
                assignEvent(event)
            }
            return
        }
        
        stopTimer()
        recordingEndDate = ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set(recordingEndDate, forKey: "recording.endDate")
        
        // Assigner l'événement et uploader directement
        recordingEvent = event
        recordingPhase = .uploading
        persistParticipants(event: event)
        persistRecordingState(event: event)
        finalizeAndUpload(event: event)
    }
    
    /// Assigne un événement au fichier audio finalisé et lance l'upload
    func assignEvent(_ event: CalendarEvent) {
        guard recordingPhase == .picking, let fileURL = finalizedAudioURL else {
            print("🎙️ ⚠️ assignEvent appelé hors phase picking")
            return
        }
        
        recordingEvent = event
        recordingPhase = .uploading
        
        // Persister pour recovery
        persistRecordingState(event: event)
        UserDefaults.standard.set(fileURL.path, forKey: "recording.audioFilePath")
        persistParticipants(event: event)
        
        print("🎙️ 📎 Enregistrement assigné à: \(event.displayTitle) → upload...")
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
        print("🎙️ 🗑️ Enregistrement supprimé (picking annulé)")
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
    
    /// Finalise la capture et uploade directement (mode avec événement pré-associé)
    private func finalizeAndUpload(event: CalendarEvent) {
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.stopCapture()
                print("🎙️ ✅ Fichier audio prêt: \(fileURL.lastPathComponent)")
                
                let startDate = self.recordingStartDate ?? ISO8601DateFormatter().string(from: Date())
                let endDate = self.recordingEndDate ?? ISO8601DateFormatter().string(from: Date())
                try await uploadService.uploadAudio(fileURL: fileURL, event: event, recordingStartDate: startDate, recordingEndDate: endDate)
                print("🎙️ ✅ Upload réussi")
                
                uploadService.cleanupFile(at: fileURL)
                currentRecordingURL = nil
                clearPersistedState()
                markDone()
                
            } catch {
                print("🎙️ ❌ Erreur stop/upload: \(error.localizedDescription)")
                markError(error.localizedDescription)
            }
        }
    }
    
    /// Upload un fichier déjà finalisé (après assignation d'événement)
    private func uploadFinalizedFile(fileURL: URL, event: CalendarEvent) {
        Task { @MainActor in
            do {
                let startDate = self.recordingStartDate ?? ISO8601DateFormatter().string(from: Date())
                let endDate = self.recordingEndDate ?? ISO8601DateFormatter().string(from: Date())
                try await uploadService.uploadAudio(fileURL: fileURL, event: event, recordingStartDate: startDate, recordingEndDate: endDate)
                print("🎙️ ✅ Upload réussi pour: \(event.displayTitle)")
                
                uploadService.cleanupFile(at: fileURL)
                finalizedAudioURL = nil
                currentRecordingURL = nil
                clearPersistedState()
                markDone()
                
            } catch {
                print("🎙️ ❌ Erreur upload: \(error.localizedDescription)")
                markError(error.localizedDescription)
            }
        }
    }
    
    /// Persiste les participants d'un événement pour recovery
    private func persistParticipants(event: CalendarEvent) {
        if let participants = event.allParticipants ?? event.participants,
           let jsonData = try? JSONEncoder().encode(participants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            UserDefaults.standard.set(jsonString, forKey: "recording.participantsJSON")
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
    private func persistRecordingState(event: CalendarEvent?) {
        let defaults = UserDefaults.standard
        defaults.set(event?.id ?? "free-recording", forKey: Self.kEventId)
        defaults.set(event?.displayTitle ?? "Enregistrement libre", forKey: Self.kEventTitle)
        defaults.set(event?.notionPageId ?? "", forKey: Self.kNotionPageId)
        defaults.set(recordingStartDate, forKey: Self.kStartDate)
        defaults.set(true, forKey: Self.kIsActive)
        print("🎙️ 💾 État persisté (event: \(event?.displayTitle ?? "libre"))")
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
    
    /// Vérifie si un enregistrement interrompu peut être récupéré.
    /// Ne retourne rien si un enregistrement est actuellement en cours.
    func checkForRecovery() -> RecoveredRecording? {
        // GUARD: ne pas interférer avec un enregistrement actif ou un picking
        guard !isRecording, recordingPhase == .idle else {
            print("🎙️ ⏭ Recovery ignorée : enregistrement en cours")
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
        
        // Si c'était un enregistrement libre (pas encore assigné), passer en picking
        if notionPageId.isEmpty {
            print("🎙️ 🔄 Enregistrement libre récupéré → phase picking")
            finalizedAudioURL = URL(fileURLWithPath: audioFilePath)
            recordingStartDate = startDate
            recordingEndDate = endDate
            recordingPhase = .picking
            return nil // Pas de recovery auto — l'utilisateur va choisir l'événement
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
                
                uploadService.cleanupFile(at: fileURL)
                clearPersistedState()
                print("🎙️ ✅ Recovery upload réussi pour: \(recovered.eventTitle)")
                markDone()
                
            } catch {
                print("🎙️ ❌ Recovery upload échoué: \(error.localizedDescription)")
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
    case picking    // En attente de sélection d'événement après stop
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
