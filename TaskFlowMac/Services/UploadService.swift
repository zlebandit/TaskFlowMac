//
//  UploadService.swift
//  TaskFlowMac
//
//  Upload multipart/form-data du fichier audio vers n8n
//  pour transcription via Gemini.
//
//  Endpoint : Config.transcribeURL (webhook taskflow-transcribe)
//  Workflow n8n : lLIDlf1W4H1qNDeq (TaskFlow Transcription Réunion)
//
//  Fonctionnalités :
//    - Retry avec backoff exponentiel (3 tentatives : 2s → 5s → 10s)
//    - Validation fichier avant upload (taille min 10 KB, max 500 MB)
//    - Streaming par chunks de 1 Mo (pas de chargement intégral en RAM)
//    - Distinction erreurs retryables vs non-retryables
//

import Foundation

/// Erreurs d'upload
enum UploadError: LocalizedError {
    case fileNotFound
    case fileTooSmall(Int)
    case fileTooLarge(Int)
    case invalidURL
    case serverError(statusCode: Int, body: String)
    case networkError(String)
    case allRetriesFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "Fichier audio introuvable"
        case .fileTooSmall(let bytes): return "Fichier audio trop petit (\(bytes) octets) — enregistrement vide ?"
        case .fileTooLarge(let mb): return "Fichier audio trop volumineux (\(mb) MB)"
        case .invalidURL: return "URL d'upload invalide"
        case .serverError(let code, let body): return "Erreur serveur (\(code)): \(body)"
        case .networkError(let msg): return "Erreur réseau: \(msg)"
        case .allRetriesFailed(let msg): return "Échec après 3 tentatives : \(msg)"
        }
    }
    
    /// Indique si l'erreur justifie un retry
    var isRetryable: Bool {
        switch self {
        case .networkError: return true
        case .serverError(let code, _): return code >= 500 || code == 408 || code == 429
        default: return false
        }
    }
}

struct UploadService {
    
    // MARK: - Configuration
    
    private static let maxRetries = 3
    private static let retryDelays: [UInt64] = [
        2_000_000_000,   // 2s
        5_000_000_000,   // 5s
        10_000_000_000   // 10s
    ]
    private static let minAudioSize = 10_240        // 10 KB
    private static let maxAudioSize = 500 * 1_048_576 // 500 MB
    private static let chunkSize = 1_048_576          // 1 MB pour le streaming
    
    // MARK: - Upload with Retry
    
    /// Upload le fichier audio vers n8n pour transcription, avec retry automatique.
    /// - Parameters:
    ///   - fileURL: URL du fichier audio M4A
    ///   - event: Réunion associée
    ///   - recordingStartDate: Date ISO8601 de début d'enregistrement
    ///   - recordingEndDate: Date ISO8601 de fin d'enregistrement
    func uploadAudio(fileURL: URL, event: CalendarEvent, recordingStartDate: String, recordingEndDate: String) async throws {
        // 1. Valider le fichier
        try validateAudioFile(at: fileURL)
        
        guard let webhookURL = URL(string: Config.transcribeURL) else {
            throw UploadError.invalidURL
        }
        
        // 2. Préparer les champs metadata
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        var fields: [(String, String)] = [
            ("eventTitle", event.displayTitle),
            ("notionPageId", event.notionPageId),
            ("eventDate", dateFormatter.string(from: Date())),
            ("startDate", recordingStartDate),
            ("endDate", recordingEndDate),
            ("source", "taskflow-mac")
        ]
        
        if let participants = event.allParticipants ?? event.participants,
           let jsonData = try? JSONEncoder().encode(participants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            fields.append(("participants", jsonString))
        }
        
        // 3. Tentatives avec retry
        var lastError: UploadError?
        
        for attempt in 1...Self.maxRetries {
            do {
                try await performUpload(
                    webhookURL: webhookURL,
                    audioFileURL: fileURL,
                    fields: fields
                )
                
                if attempt > 1 {
                    print("🎙️ ✅ Upload réussi à la tentative \(attempt)")
                } else {
                    print("🎙️ ✅ Upload réussi")
                }
                return
                
            } catch let error as UploadError {
                lastError = error
                print("🎙️ ⚠️ Tentative \(attempt)/\(Self.maxRetries) échouée: \(error.localizedDescription ?? "unknown")")
                
                guard error.isRetryable, attempt < Self.maxRetries else { break }
                
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                print("🎙️ ⏳ Retry dans \(delay / 1_000_000_000)s...")
                try? await Task.sleep(nanoseconds: delay)
                
            } catch {
                let nsError = error as NSError
                lastError = .networkError("\(nsError.localizedDescription) (code \(nsError.code))")
                print("🎙️ ⚠️ Tentative \(attempt)/\(Self.maxRetries) - Erreur réseau: \(error.localizedDescription)")
                
                guard attempt < Self.maxRetries else { break }
                
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                print("🎙️ ⏳ Retry dans \(delay / 1_000_000_000)s...")
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        
        throw UploadError.allRetriesFailed(lastError?.localizedDescription ?? "Erreur inconnue")
    }
    
    /// Upload avec des métadonnées brutes (pour recovery depuis UserDefaults)
    func uploadRecoveredAudio(
        fileURL: URL,
        eventTitle: String,
        notionPageId: String,
        eventDate: String,
        startDate: String,
        endDate: String,
        participantsJSON: String
    ) async throws {
        try validateAudioFile(at: fileURL)
        
        guard let webhookURL = URL(string: Config.transcribeURL) else {
            throw UploadError.invalidURL
        }
        
        let fields: [(String, String)] = [
            ("eventTitle", eventTitle),
            ("notionPageId", notionPageId),
            ("eventDate", eventDate),
            ("startDate", startDate),
            ("endDate", endDate),
            ("participants", participantsJSON),
            ("source", "taskflow-mac")
        ]
        
        var lastError: UploadError?
        
        for attempt in 1...Self.maxRetries {
            do {
                try await performUpload(webhookURL: webhookURL, audioFileURL: fileURL, fields: fields)
                print("🎙️ ✅ Upload recovery réussi (tentative \(attempt))")
                return
            } catch let error as UploadError {
                lastError = error
                guard error.isRetryable, attempt < Self.maxRetries else { break }
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                try? await Task.sleep(nanoseconds: delay)
            } catch {
                lastError = .networkError(error.localizedDescription)
                guard attempt < Self.maxRetries else { break }
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        
        throw UploadError.allRetriesFailed(lastError?.localizedDescription ?? "Erreur inconnue")
    }
    
    /// Supprime le fichier audio local
    func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        print("🎙️ 🗑️ Fichier audio supprimé: \(url.lastPathComponent)")
    }
    
    // MARK: - File Validation
    
    private func validateAudioFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UploadError.fileNotFound
        }
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs?[.size] as? Int ?? 0
        
        if fileSize < Self.minAudioSize {
            throw UploadError.fileTooSmall(fileSize)
        }
        
        if fileSize > Self.maxAudioSize {
            throw UploadError.fileTooLarge(fileSize / 1_048_576)
        }
        
        let sizeMB = Double(fileSize) / 1_048_576
        print("🎙️ 📁 Fichier audio validé: \(String(format: "%.1f", sizeMB)) MB")
    }
    
    // MARK: - Single Upload Attempt (streaming)
    
    private func performUpload(
        webhookURL: URL,
        audioFileURL: URL,
        fields: [(String, String)]
    ) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // 5 min pour les gros fichiers
        
        // Construire le body dans un fichier temporaire (streaming, pas tout en RAM)
        let tempBodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).tmp")
        
        defer {
            try? FileManager.default.removeItem(at: tempBodyURL)
        }
        
        try buildMultipartBody(
            to: tempBodyURL,
            boundary: boundary,
            audioFileURL: audioFileURL,
            fields: fields
        )
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: tempBodyURL)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.networkError("Réponse HTTP invalide")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "No body"
            throw UploadError.serverError(statusCode: httpResponse.statusCode, body: body)
        }
        
        print("🎙️ ✅ Upload réussi (HTTP \(httpResponse.statusCode))")
    }
    
    // MARK: - Multipart Body Builder (streaming)
    
    /// Écrit le body multipart dans un fichier temporaire.
    /// Le fichier audio est streamé par chunks de 1 MB.
    private func buildMultipartBody(
        to outputURL: URL,
        boundary: String,
        audioFileURL: URL,
        fields: [(String, String)]
    ) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        
        // Champs texte
        for (name, value) in fields {
            handle.write("--\(boundary)\r\n".data(using: .utf8)!)
            handle.write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            handle.write("\(value)\r\n".data(using: .utf8)!)
        }
        
        // Fichier audio (streamé par chunks)
        handle.write("--\(boundary)\r\n".data(using: .utf8)!)
        handle.write("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        handle.write("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        
        let audioHandle = try FileHandle(forReadingFrom: audioFileURL)
        defer { try? audioHandle.close() }
        
        while autoreleasepool(invoking: {
            let chunk = audioHandle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty { return false }
            handle.write(chunk)
            return true
        }) { }
        
        handle.write("\r\n".data(using: .utf8)!)
        handle.write("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}
