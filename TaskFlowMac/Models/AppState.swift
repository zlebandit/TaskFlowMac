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
//  Persistance :
//    - Sidecar JSON à côté de chaque fichier .m4a (via PendingUploadManager)
//    - UserDefaults uniquement pour crash recovery PENDANT un enregistrement actif
//    - Au lancement : migration UserDefaults → sidecar + scan du répertoire
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
            print("\u{1f399}\u{fe0f} \u{2705} JSON écrit: \(path)")
        } catch {
            print("\u{1f399}\u{fe0f} \u{274c} Erreur écriture JSON: \(error)")
        }
    }
    
    // MARK: - Sync
    
    /// Sync les réunions du jour depuis le serveur (avec debounce)
    func syncMeetings() async {
        if let lastSync = lastSyncDate,
           Date().timeIntervalSince(lastSync) < Config.minSyncInterval {
            return
        }
        await forceSyncMeetings()
    }
    
    /// Force la sync des réunions (sans debounce, pour le bouton refresh)
    func forceSyncMeetings() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let fetched = try await SyncService().fetchMeetings()
            meetings = fetched
            saveCacheToDisk()
            writeMeetingsJSONFile()
            lastSyncDate = Date()
            print("\u{2705} Sync: \(fetched.count) réunions")
        } catch {
            print("\u{274c} Sync failed: \(error.localizedDescription)")
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
    
    // MARK: - Pending Uploads (sidecar-based)
    
    /// Fichiers en attente d'upload (détectés par scan du répertoire + sidecars)
    var pendingUploads: [PendingUploadInfo] = []
    
    /// Indique si un retry du pending upload est en cours
    var isRetryingPendingUpload = false
    
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
    
    // MARK: - Alfred JSON (Codable)
    
    /// Modèle Alfred Script Filter
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
    
    /// JSON des réunions du jour au format Alfred Script Filter
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
    
    // MARK: - Recording Actions
    
    /// Démarre la capture audio micro.
    /// - Sans event : enregistrement libre (picking après stop)
    /// - Avec event : mode classique (upload direct après stop)
    func startRecording(for event: CalendarEvent? = nil) {
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
                UserDefaults.standard.set(fileURL.path, forKey: Self.kAudioFilePath)
                let label = event.map { $0.displayTitle } ?? "libre"
                print("\u{1f399}\u{fe0f} \u{2705} Capture démarrée (\(label)) \u{2192} \(fileURL.lastPathComponent)")
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Erreur démarrage capture: \(error.localizedDescription)")
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
    
    /// Arrête la capture.
    /// - Si un événement est déjà associé → upload directement
    /// - Sinon → passe en phase .picking (sélection d'événement)
    func stopRecording() {
        stopTimer()
        recordingEndDate = ISO8601DateFormatter().string(from: Date())
        
        // Persister la date de fin pour recovery
        UserDefaults.standard.set(recordingEndDate, forKey: Self.kEndDate)
        
        if let event = recordingEvent {
            // Mode classique : événement déjà associé → upload direct
            recordingPhase = .uploading
            finalizeAndUpload(event: event)
        } else {
            // Mode libre : finaliser le fichier et passer en picking
            recordingPhase = .uploading // temporaire pendant la finalisation
            Task { @MainActor in
                do {
                    let fileURL = try await audioCaptureService.stopCapture()
                    self.finalizedAudioURL = fileURL
                    self.currentRecordingURL = nil
                    
                    // Créer le sidecar initial (enregistrement libre, pas encore assigné)
                    let metadata = UploadMetadata(
                        startDate: self.recordingStartDate ?? "",
                        endDate: self.recordingEndDate ?? ""
                    )
                    PendingUploadManager.saveSidecar(for: fileURL, metadata: metadata)
                    
                    self.recordingPhase = .picking
                    print("\u{1f399}\u{fe0f} \u{2705} Fichier audio prêt, en attente d'affectation: \(fileURL.lastPathComponent)")
                } catch {
                    print("\u{1f399}\u{fe0f} \u{274c} Erreur finalisation: \(error.localizedDescription)")
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
        UserDefaults.standard.set(recordingEndDate, forKey: Self.kEndDate)
        
        // Assigner l'événement et uploader directement
        recordingEvent = event
        recordingPhase = .uploading
        persistRecordingState(event: event)
        finalizeAndUpload(event: event)
    }
    
    /// Assigne un événement au fichier audio finalisé et lance l'upload
    func assignEvent(_ event: CalendarEvent) {
        guard recordingPhase == .picking, let fileURL = finalizedAudioURL else {
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} assignEvent appelé hors phase picking")
            return
        }
        
        recordingEvent = event
        recordingPhase = .uploading
        
        // Mettre à jour le sidecar avec l'événement
        let participantsJSON = encodeParticipants(event: event)
        PendingUploadManager.assignEvent(
            for: fileURL,
            eventId: event.id,
            eventTitle: event.displayTitle,
            notionPageId: event.notionPageId,
            participantsJSON: participantsJSON
        )
        
        print("\u{1f399}\u{fe0f} \u{1f4ce} Enregistrement assigné à: \(event.displayTitle) \u{2192} upload...")
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
        print("\u{1f399}\u{fe0f} \u{1f5d1}\u{fe0f} Enregistrement supprimé (picking annulé)")
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
        // Scanner les fichiers en attente d'upload
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
    
    /// Scanne le répertoire d'enregistrements via PendingUploadManager.
    /// Source de vérité = filesystem + sidecars JSON.
    /// À appeler à chaque ouverture du popover et après chaque reset.
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
    
    /// Prépare un fichier en attente pour l'assignation à une réunion (mode picking)
    func assignPendingUpload(_ pending: PendingUploadInfo) {
        finalizedAudioURL = pending.audioURL
        recordingStartDate = pending.metadata?.startDate
        recordingEndDate = pending.metadata?.endDate
        
        pendingUploads = []
        recordingPhase = .picking
    }
    
    /// Retente l'upload d'un fichier en attente qui a déjà un événement assigné
    func retryPendingUpload(_ pending: PendingUploadInfo) {
        guard pending.isAssigned else {
            // Pas d'événement assigné → passer en picking
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
    
    /// Supprime définitivement un fichier en attente d'upload (audio + sidecar)
    func discardPendingUpload(_ pending: PendingUploadInfo) {
        PendingUploadManager.deletePending(audioURL: pending.audioURL)
        pendingUploads.removeAll { $0.id == pending.id }
    }
    
    // MARK: - Initialization (appelé au lancement)
    
    /// Migration UserDefaults → sidecar + scan initial.
    /// À appeler une seule fois au lancement de l'app.
    func initializePendingUploads() {
        // 1. Migrer les anciennes métadonnées UserDefaults vers sidecar
        PendingUploadManager.migrateFromUserDefaults()
        
        // 2. Scanner les fichiers en attente
        scanPendingUploads()
        
        // 3. Auto-retry des fichiers assignés (en background)
        let assignedPendings = pendingUploads.filter { $0.isAssigned }
        if !assignedPendings.isEmpty {
            print("\u{1f399}\u{fe0f} \u{1f504} \(assignedPendings.count) fichier(s) assigné(s) en attente d'upload")
            Task { @MainActor in
                for pending in assignedPendings {
                    let success = await PendingUploadManager.uploadPending(pending)
                    if success {
                        print("\u{1f399}\u{fe0f} \u{2705} Auto-retry réussi: \(pending.metadata?.eventTitle ?? pending.id)")
                    }
                }
                self.scanPendingUploads()
            }
        }
    }
    
    // MARK: - Private Upload Helpers
    
    /// Finalise la capture et uploade directement (mode avec événement pré-associé)
    private func finalizeAndUpload(event: CalendarEvent) {
        Task { @MainActor in
            do {
                let fileURL = try await audioCaptureService.stopCapture()
                self.currentRecordingURL = nil
                print("\u{1f399}\u{fe0f} \u{2705} Fichier audio prêt: \(fileURL.lastPathComponent)")
                
                // Créer le sidecar avec les métadonnées complètes
                let participantsJSON = encodeParticipants(event: event)
                let metadata = UploadMetadata(
                    eventId: event.id,
                    eventTitle: event.displayTitle,
                    notionPageId: event.notionPageId,
                    startDate: self.recordingStartDate ?? ISO8601DateFormatter().string(from: Date()),
                    endDate: self.recordingEndDate ?? ISO8601DateFormatter().string(from: Date()),
                    participantsJSON: participantsJSON
                )
                PendingUploadManager.saveSidecar(for: fileURL, metadata: metadata)
                
                // Tenter l'upload
                let startDate = self.recordingStartDate ?? ISO8601DateFormatter().string(from: Date())
                let endDate = self.recordingEndDate ?? ISO8601DateFormatter().string(from: Date())
                try await uploadService.uploadAudio(fileURL: fileURL, event: event, recordingStartDate: startDate, recordingEndDate: endDate)
                print("\u{1f399}\u{fe0f} \u{2705} Upload réussi")
                
                // Succès → supprimer audio + sidecar
                PendingUploadManager.deletePending(audioURL: fileURL)
                clearPersistedState()
                markDone()
                
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Erreur stop/upload: \(error.localizedDescription)")
                
                // Enregistrer l'échec dans le sidecar
                if let fileURL = self.audioCaptureService.outputURL ?? self.currentRecordingURL {
                    PendingUploadManager.recordFailure(for: fileURL, error: error.localizedDescription)
                }
                clearPersistedState()
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
                print("\u{1f399}\u{fe0f} \u{2705} Upload réussi pour: \(event.displayTitle)")
                
                // Succès → supprimer audio + sidecar
                PendingUploadManager.deletePending(audioURL: fileURL)
                finalizedAudioURL = nil
                clearPersistedState()
                markDone()
                
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Erreur upload: \(error.localizedDescription)")
                
                // Enregistrer l'échec dans le sidecar (le fichier reste pour retry)
                PendingUploadManager.recordFailure(for: fileURL, error: error.localizedDescription)
                clearPersistedState()
                markError(error.localizedDescription)
            }
        }
    }
    
    /// Encode les participants d'un événement en JSON string
    private func encodeParticipants(event: CalendarEvent) -> String {
        if let participants = event.allParticipants ?? event.participants,
           let jsonData = try? JSONEncoder().encode(participants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "[]"
    }
    
    // MARK: - Persistence (UserDefaults) pour recovery PENDANT enregistrement actif
    //
    // UserDefaults sert uniquement de filet de sécurité pendant qu'un enregistrement
    // est en cours (crash recovery). Dès que le fichier est finalisé, le sidecar JSON
    // prend le relais comme source de vérité.
    
    private static let kEventId = "recording.eventId"
    private static let kEventTitle = "recording.eventTitle"
    private static let kNotionPageId = "recording.notionPageId"
    private static let kAudioFilePath = "recording.audioFilePath"
    private static let kStartDate = "recording.startDate"
    private static let kEndDate = "recording.endDate"
    private static let kParticipantsJSON = "recording.participantsJSON"
    private static let kIsActive = "recording.isActive"
    
    /// Persiste l'état d'enregistrement (crash recovery)
    private func persistRecordingState(event: CalendarEvent?) {
        let defaults = UserDefaults.standard
        defaults.set(event?.id ?? "free-recording", forKey: Self.kEventId)
        defaults.set(event?.displayTitle ?? "Enregistrement libre", forKey: Self.kEventTitle)
        defaults.set(event?.notionPageId ?? "", forKey: Self.kNotionPageId)
        defaults.set(recordingStartDate, forKey: Self.kStartDate)
        defaults.set(true, forKey: Self.kIsActive)
        
        if let event = event {
            let participantsJSON = encodeParticipants(event: event)
            defaults.set(participantsJSON, forKey: Self.kParticipantsJSON)
        }
        
        print("\u{1f399}\u{fe0f} \u{1f4be} État persisté (event: \(event?.displayTitle ?? "libre"))")
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
    /// Note: avec le sidecar, cette méthode est surtout utile pour les crash
    /// survenus PENDANT un enregistrement (avant la finalisation du fichier).
    func checkForRecovery() -> RecoveredRecording? {
        // GUARD: ne pas interférer avec un enregistrement actif ou un picking
        guard !isRecording, recordingPhase == .idle else {
            print("\u{1f399}\u{fe0f} \u{23ed} Recovery ignorée : enregistrement en cours")
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
            print("\u{1f399}\u{fe0f} \u{26a0}\u{fe0f} Fichier audio disparu: \(audioFilePath)")
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
        print("\u{1f399}\u{fe0f} \u{1f504} Enregistrement récupérable trouvé: \(eventTitle) (\(String(format: "%.1f", sizeMB)) MB)")
        
        // Créer un sidecar pour le fichier récupéré (migration vers le nouveau système)
        let audioURL = URL(fileURLWithPath: audioFilePath)
        let sidecarMetadata = UploadMetadata(
            eventId: defaults.string(forKey: Self.kEventId) ?? "",
            eventTitle: eventTitle,
            notionPageId: notionPageId,
            startDate: startDate,
            endDate: endDate,
            participantsJSON: participantsJSON
        )
        PendingUploadManager.saveSidecar(for: audioURL, metadata: sidecarMetadata)
        
        // Si c'était un enregistrement libre (pas encore assigné), passer en picking
        if notionPageId.isEmpty {
            print("\u{1f399}\u{fe0f} \u{1f504} Enregistrement libre récupéré → phase picking")
            finalizedAudioURL = audioURL
            recordingStartDate = startDate
            recordingEndDate = endDate
            recordingPhase = .picking
            clearPersistedState()
            return nil // Pas de recovery auto — l'utilisateur va choisir l'événement
        }
        
        clearPersistedState()
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
                
                // Succès → supprimer audio + sidecar
                PendingUploadManager.deletePending(audioURL: fileURL)
                print("\u{1f399}\u{fe0f} \u{2705} Recovery upload réussi pour: \(recovered.eventTitle)")
                markDone()
                
            } catch {
                print("\u{1f399}\u{fe0f} \u{274c} Recovery upload échoué: \(error.localizedDescription)")
                
                // Enregistrer l'échec dans le sidecar
                let fileURL = URL(fileURLWithPath: recovered.audioFilePath)
                PendingUploadManager.recordFailure(for: fileURL, error: error.localizedDescription)
                markError("Upload échoué : \(recovered.eventTitle). Le fichier reste en attente.")
            }
        }
    }
    
    /// Supprime un enregistrement récupéré (choix utilisateur)
    func discardRecoveredRecording(_ recovered: RecoveredRecording) {
        let audioURL = URL(fileURLWithPath: recovered.audioFilePath)
        PendingUploadManager.deletePending(audioURL: audioURL)
        print("\u{1f399}\u{fe0f} \u{1f5d1}\u{fe0f} Enregistrement récupéré supprimé: \(recovered.eventTitle)")
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
