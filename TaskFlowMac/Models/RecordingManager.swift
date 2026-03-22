//
//  RecordingManager.swift
//  TaskFlowMac
//
//  Gère tout le cycle de vie de l'enregistrement audio :
//  state machine, capture micro, upload, pending uploads, persistence.
//
//  Extrait de AppState pour respecter le principe de responsabilité unique.
//  AppState reste l'orchestrateur calendrier + Alfred, et délègue ici.
//
//  Flux d'enregistrement :
//    1. startRecording() ou startRecording(for:) → capture micro
//    2. (optionnel) pauseRecording() / resumeRecording()
//    3. stopRecording() → arrête la capture, passe en .picking ou .uploading
//    4. assignEvent(_:) → associe un événement et upload vers n8n
//       OU cancelPicking() → annule et supprime le fichier
//

import SwiftUI
import Observation

@Observable
class RecordingManager {
    
    // MARK: - Recording State
    
    var recordingPhase: RecordingPhase = .idle
    var recordingEvent: CalendarEvent?
    var elapsedSeconds: Int = 0
    
    private var timer: Timer?
    private let audioCaptureService = AudioCaptureService()
    private let uploadService = UploadService()
    private var currentRecordingURL: URL?
    var finalizedAudioURL: URL?
    private var recordingStartDate: String?
    private var recordingEndDate: String?
    
    // MARK: - Pending Uploads (sidecar-based)
    
    var pendingUploads: [PendingUploadInfo] = []
    var isRetryingPendingUpload = false
    
    // MARK: - Computed
    
    var isRecording: Bool {
        switch recordingPhase {
        case .recording, .paused: return true
        default: return false
        }
    }
    
    var isPicking: Bool {
        recordingPhase == .picking
    }
    
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
    
    /// Démarre la capture audio micro.
    /// - Sans event : enregistrement libre (picking après stop)
    /// - Avec event : mode classique (upload direct après stop)
    func startRecording(for event: CalendarEvent? = nil) {
        recordingEvent = event
        recordingPhase = .recording
        elapsedSeconds = 0
        recordingStartDate = Config.isoFormatter.string(from: Date())
        recordingEndDate = nil
        finalizedAudioURL = nil
        startTimer()
        
        persistRecordingState(event: event)
        
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.startCapture()
                currentRecordingURL = fileURL
                UserDefaults.standard.set(fileURL.path, forKey: Self.kAudioFilePath)
                let label = event.map { $0.displayTitle } ?? "libre"
                print("[Rec] Capture démarrée (\(label)) -> \(fileURL.lastPathComponent)")
            } catch {
                print("[Rec] Erreur démarrage capture: \(error.localizedDescription)")
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
        print("[Rec] Enregistrement en pause")
    }
    
    /// Reprend l'enregistrement après pause
    func resumeRecording() {
        guard recordingPhase == .paused else { return }
        do {
            try audioCaptureService.resumeCapture()
            recordingPhase = .recording
            startTimer()
            print("[Rec] Enregistrement repris")
        } catch {
            print("[Rec] Erreur reprise: \(error.localizedDescription)")
            recordingPhase = .error(error.localizedDescription)
        }
    }
    
    /// Arrête la capture.
    /// - Si un événement est déjà associé → upload directement
    /// - Sinon → passe en phase .picking (sélection d'événement)
    func stopRecording() {
        stopTimer()
        recordingEndDate = Config.isoFormatter.string(from: Date())
        UserDefaults.standard.set(recordingEndDate, forKey: Self.kEndDate)
        
        if let event = recordingEvent {
            recordingPhase = .uploading
            finalizeAndUpload(event: event)
        } else {
            recordingPhase = .uploading
            Task { @MainActor in
                do {
                    let fileURL = try await audioCaptureService.stopCapture()
                    self.finalizedAudioURL = fileURL
                    self.currentRecordingURL = nil
                    
                    let metadata = UploadMetadata(
                        startDate: self.recordingStartDate ?? "",
                        endDate: self.recordingEndDate ?? ""
                    )
                    PendingUploadManager.saveSidecar(for: fileURL, metadata: metadata)
                    
                    self.recordingPhase = .picking
                    print("[Rec] Fichier audio pret, en attente d'affectation: \(fileURL.lastPathComponent)")
                } catch {
                    print("[Rec] Erreur finalisation: \(error.localizedDescription)")
                    self.markError(error.localizedDescription)
                }
            }
        }
    }
    
    /// Stop + Assign en une seule commande (pour Alfred fr)
    func stopAndAssign(_ event: CalendarEvent) {
        guard isRecording else {
            if recordingPhase == .picking {
                assignEvent(event)
            }
            return
        }
        
        stopTimer()
        recordingEndDate = Config.isoFormatter.string(from: Date())
        UserDefaults.standard.set(recordingEndDate, forKey: Self.kEndDate)
        
        recordingEvent = event
        recordingPhase = .uploading
        persistRecordingState(event: event)
        finalizeAndUpload(event: event)
    }
    
    /// Assigne un événement au fichier audio finalisé et lance l'upload
    func assignEvent(_ event: CalendarEvent) {
        guard recordingPhase == .picking, let fileURL = finalizedAudioURL else {
            print("[Rec] assignEvent appelé hors phase picking")
            return
        }
        
        recordingEvent = event
        recordingPhase = .uploading
        
        let participantsJSON = encodeParticipants(event: event)
        PendingUploadManager.assignEvent(
            for: fileURL,
            eventId: event.id,
            eventTitle: event.displayTitle,
            notionPageId: event.notionPageId,
            participantsJSON: participantsJSON
        )
        
        print("[Rec] Enregistrement assigné a: \(event.displayTitle) -> upload...")
        uploadFinalizedFile(fileURL: fileURL, event: event)
    }
    
    /// Annule la phase de picking (supprime le fichier audio + sidecar)
    func cancelPicking() {
        guard recordingPhase == .picking else { return }
        
        if let fileURL = finalizedAudioURL {
            PendingUploadManager.deletePending(audioURL: fileURL)
        }
        clearPersistedState()
        reset()
        print("[Rec] Enregistrement supprimé (picking annulé)")
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
        scanPendingUploads()
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
    
    // MARK: - Pending Upload Management (sidecar-based)
    
    func scanPendingUploads() {
        guard !isRecording,
              recordingPhase == .idle || recordingPhase == .done else {
            pendingUploads = []
            return
        }
        
        pendingUploads = PendingUploadManager.scanPendingUploads(
            activeFilePath: currentRecordingURL?.path
        )
    }
    
    func assignPendingUpload(_ pending: PendingUploadInfo) {
        finalizedAudioURL = pending.audioURL
        recordingStartDate = pending.metadata?.startDate
        recordingEndDate = pending.metadata?.endDate
        
        pendingUploads = []
        recordingPhase = .picking
    }
    
    func retryPendingUpload(_ pending: PendingUploadInfo) {
        guard pending.isAssigned else {
            assignPendingUpload(pending)
            return
        }
        
        isRetryingPendingUpload = true
        
        Task { @MainActor in
            let success = await PendingUploadManager.uploadPending(pending)
            self.isRetryingPendingUpload = false
            
            if success {
                self.scanPendingUploads()
            }
        }
    }
    
    func discardPendingUpload(_ pending: PendingUploadInfo) {
        PendingUploadManager.deletePending(audioURL: pending.audioURL)
        pendingUploads.removeAll { $0.id == pending.id }
    }
    
    // MARK: - Initialization (appelé au lancement)
    
    func initializePendingUploads() {
        PendingUploadManager.migrateFromUserDefaults()
        scanPendingUploads()
        
        let assignedPendings = pendingUploads.filter { $0.isAssigned }
        if !assignedPendings.isEmpty {
            print("[Rec] \(assignedPendings.count) fichier(s) assigné(s) en attente d'upload")
            Task { @MainActor in
                for pending in assignedPendings {
                    let success = await PendingUploadManager.uploadPending(pending)
                    if success {
                        print("[Rec] Auto-retry réussi: \(pending.metadata?.eventTitle ?? pending.id)")
                    }
                }
                self.scanPendingUploads()
            }
        }
    }
    
    // MARK: - Private Upload Helpers
    
    private func finalizeAndUpload(event: CalendarEvent) {
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.stopCapture()
                self.currentRecordingURL = nil
                print("[Rec] Fichier audio pret: \(fileURL.lastPathComponent)")
                
                let participantsJSON = encodeParticipants(event: event)
                let metadata = UploadMetadata(
                    eventId: event.id,
                    eventTitle: event.displayTitle,
                    notionPageId: event.notionPageId,
                    startDate: self.recordingStartDate ?? Config.isoFormatter.string(from: Date()),
                    endDate: self.recordingEndDate ?? Config.isoFormatter.string(from: Date()),
                    participantsJSON: participantsJSON
                )
                PendingUploadManager.saveSidecar(for: fileURL, metadata: metadata)
                
                let startDate = self.recordingStartDate ?? Config.isoFormatter.string(from: Date())
                let endDate = self.recordingEndDate ?? Config.isoFormatter.string(from: Date())
                try await uploadService.uploadAudio(
                    fileURL: fileURL,
                    event: event,
                    recordingStartDate: startDate,
                    recordingEndDate: endDate
                )
                print("[Rec] Upload réussi")
                
                PendingUploadManager.deletePending(audioURL: fileURL)
                clearPersistedState()
                markDone()
                
            } catch {
                print("[Rec] Erreur stop/upload: \(error.localizedDescription)")
                
                if let fileURL = self.audioCaptureService.outputURL ?? self.currentRecordingURL {
                    PendingUploadManager.recordFailure(for: fileURL, error: error.localizedDescription)
                }
                clearPersistedState()
                markError(error.localizedDescription)
            }
        }
    }
    
    private func uploadFinalizedFile(fileURL: URL, event: CalendarEvent) {
        Task { @MainActor in
            do {
                let startDate = self.recordingStartDate ?? Config.isoFormatter.string(from: Date())
                let endDate = self.recordingEndDate ?? Config.isoFormatter.string(from: Date())
                try await uploadService.uploadAudio(
                    fileURL: fileURL,
                    event: event,
                    recordingStartDate: startDate,
                    recordingEndDate: endDate
                )
                print("[Rec] Upload réussi pour: \(event.displayTitle)")
                
                PendingUploadManager.deletePending(audioURL: fileURL)
                finalizedAudioURL = nil
                clearPersistedState()
                markDone()
                
            } catch {
                print("[Rec] Erreur upload: \(error.localizedDescription)")
                PendingUploadManager.recordFailure(for: fileURL, error: error.localizedDescription)
                clearPersistedState()
                markError(error.localizedDescription)
            }
        }
    }
    
    private func encodeParticipants(event: CalendarEvent) -> String {
        if let participants = event.allParticipants ?? event.participants,
           let jsonData = try? JSONEncoder().encode(participants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "[]"
    }
    
    // MARK: - Persistence (UserDefaults) — crash recovery PENDANT enregistrement actif
    //
    // UserDefaults sert uniquement de filet de sécurité pendant qu'un enregistrement
    // est en cours (crash recovery). Dès que le fichier est finalisé, le sidecar JSON
    // prend le relais comme source de vérité.
    
    private static let kEventId        = "recording.eventId"
    private static let kEventTitle     = "recording.eventTitle"
    private static let kNotionPageId   = "recording.notionPageId"
    private static let kAudioFilePath  = "recording.audioFilePath"
    private static let kStartDate      = "recording.startDate"
    private static let kEndDate        = "recording.endDate"
    private static let kParticipantsJSON = "recording.participantsJSON"
    private static let kIsActive       = "recording.isActive"
    
    private func persistRecordingState(event: CalendarEvent?) {
        let defaults = UserDefaults.standard
        defaults.set(event?.id ?? "free-recording",             forKey: Self.kEventId)
        defaults.set(event?.displayTitle ?? "Enregistrement libre", forKey: Self.kEventTitle)
        defaults.set(event?.notionPageId ?? "",                 forKey: Self.kNotionPageId)
        defaults.set(recordingStartDate,                        forKey: Self.kStartDate)
        defaults.set(true,                                      forKey: Self.kIsActive)
        
        if let event = event {
            defaults.set(encodeParticipants(event: event), forKey: Self.kParticipantsJSON)
        }
        print("[Rec] Etat persisté (event: \(event?.displayTitle ?? "libre"))")
    }
    
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
    
    // MARK: - Recovery
    
    struct RecoveredRecording {
        let eventTitle: String
        let notionPageId: String
        let audioFilePath: String
        let startDate: String
        let endDate: String
        let participantsJSON: String
    }
    
    func checkForRecovery() -> RecoveredRecording? {
        guard !isRecording, recordingPhase == .idle else {
            print("[Rec] Recovery ignorée : enregistrement en cours")
            return nil
        }
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.kIsActive),
              let eventTitle    = defaults.string(forKey: Self.kEventTitle),
              let audioFilePath = defaults.string(forKey: Self.kAudioFilePath),
              let startDate     = defaults.string(forKey: Self.kStartDate) else {
            return nil
        }
        
        let notionPageId   = defaults.string(forKey: Self.kNotionPageId) ?? ""
        let endDate        = defaults.string(forKey: Self.kEndDate) ?? Config.isoFormatter.string(from: Date())
        let participantsJSON = defaults.string(forKey: Self.kParticipantsJSON) ?? "[]"
        
        guard FileManager.default.fileExists(atPath: audioFilePath) else {
            print("[Rec] Fichier audio disparu: \(audioFilePath)")
            clearPersistedState()
            return nil
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: audioFilePath)[.size] as? Int) ?? 0
        guard size > 10_240 else {
            try? FileManager.default.removeItem(atPath: audioFilePath)
            clearPersistedState()
            return nil
        }
        
        let sizeMB = Double(size) / 1_048_576
        print("[Rec] Enregistrement récupérable trouvé: \(eventTitle) (\(String(format: "%.1f", sizeMB)) MB)")
        
        let audioURL = URL(fileURLWithPath: audioFilePath)
        let sidecarMetadata = UploadMetadata(
            eventId:          defaults.string(forKey: Self.kEventId) ?? "",
            eventTitle:       eventTitle,
            notionPageId:     notionPageId,
            startDate:        startDate,
            endDate:          endDate,
            participantsJSON: participantsJSON
        )
        PendingUploadManager.saveSidecar(for: audioURL, metadata: sidecarMetadata)
        
        if notionPageId.isEmpty {
            print("[Rec] Enregistrement libre récupéré -> phase picking")
            finalizedAudioURL = audioURL
            recordingStartDate = startDate
            recordingEndDate = endDate
            recordingPhase = .picking
            clearPersistedState()
            return nil
        }
        
        clearPersistedState()
        return RecoveredRecording(
            eventTitle:       eventTitle,
            notionPageId:     notionPageId,
            audioFilePath:    audioFilePath,
            startDate:        startDate,
            endDate:          endDate,
            participantsJSON: participantsJSON
        )
    }
    
    func retryRecoveredRecording(_ recovered: RecoveredRecording) {
        recordingPhase = .uploading
        
        let eventDate = Config.dayFormatter.string(from: Date())
        
        Task { @MainActor in
            do {
                let fileURL = URL(fileURLWithPath: recovered.audioFilePath)
                try await uploadService.uploadRecoveredAudio(
                    fileURL:          fileURL,
                    eventTitle:       recovered.eventTitle,
                    notionPageId:     recovered.notionPageId,
                    eventDate:        eventDate,
                    startDate:        recovered.startDate,
                    endDate:          recovered.endDate,
                    participantsJSON: recovered.participantsJSON
                )
                
                PendingUploadManager.deletePending(audioURL: fileURL)
                print("[Rec] Recovery upload réussi pour: \(recovered.eventTitle)")
                markDone()
                
            } catch {
                print("[Rec] Recovery upload échoué: \(error.localizedDescription)")
                let fileURL = URL(fileURLWithPath: recovered.audioFilePath)
                PendingUploadManager.recordFailure(for: fileURL, error: error.localizedDescription)
                markError("Upload échoué : \(recovered.eventTitle). Le fichier reste en attente.")
            }
        }
    }
    
    func discardRecoveredRecording(_ recovered: RecoveredRecording) {
        let audioURL = URL(fileURLWithPath: recovered.audioFilePath)
        PendingUploadManager.deletePending(audioURL: audioURL)
        print("[Rec] Enregistrement récupéré supprimé: \(recovered.eventTitle)")
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
