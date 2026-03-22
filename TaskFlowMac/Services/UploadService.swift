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
//    - Progression upload en % (bytes envoyés / total) via delegate URLSession
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
        case .fileTooSmall(let bytes): return "Fichier audio trop petit (\(bytes) octets) \u{2014} enregistrement vide ?"
        case .fileTooLarge(let mb): return "Fichier audio trop volumineux (\(mb) MB)"
        case .invalidURL: return "URL d'upload invalide"
        case .serverError(let code, let body): return "Erreur serveur (\(code)): \(body)"
        case .networkError(let msg): return "Erreur r\u{00e9}seau: \(msg)"
        case .allRetriesFailed(let msg): return "\u{00c9}chec apr\u{00e8}s 3 tentatives : \(msg)"
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

// MARK: - Upload Progress Delegate

/// Delegate URLSession qui capture la progression de l'upload (bytes envoyés / total).
/// Utilisé pour afficher un pourcentage dans la UI pendant l'envoi du fichier audio.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    /// Callback appelé sur le main thread avec la fraction envoyée (0.0 → 1.0)
    var onProgress: ((Double) -> Void)?
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(fraction)
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
    /// - Parameter onProgress: Callback progression (0.0 → 1.0), appelé sur le main thread.
    func uploadAudio(
        fileURL: URL,
        event: CalendarEvent,
        recordingStartDate: String,
        recordingEndDate: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        try validateAudioFile(at: fileURL)
        
        guard let webhookURL = URL(string: Config.transcribeURL) else {
            throw UploadError.invalidURL
        }
        
        var fields: [(String, String)] = [
            ("eventTitle", event.displayTitle),
            ("notionPageId", event.notionPageId),
            ("eventDate", Config.dayFormatter.string(from: Date())),
            ("startDate", recordingStartDate),
            ("endDate", recordingEndDate),
            ("source", "taskflow-mac")
        ]
        
        if let participants = event.allParticipants ?? event.participants,
           let jsonData = try? JSONEncoder().encode(participants),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            fields.append(("participants", jsonString))
        }
        
        try await uploadWithRetry(webhookURL: webhookURL, audioFileURL: fileURL, fields: fields, onProgress: onProgress)
    }
    
    /// Upload avec des métadonnées brutes (pour recovery depuis UserDefaults)
    func uploadRecoveredAudio(
        fileURL: URL,
        eventTitle: String,
        notionPageId: String,
        eventDate: String,
        startDate: String,
        endDate: String,
        participantsJSON: String,
        onProgress: ((Double) -> Void)? = nil
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
        
        try await uploadWithRetry(webhookURL: webhookURL, audioFileURL: fileURL, fields: fields, onProgress: onProgress)
    }
    
    /// Supprime le fichier audio local
    func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        print("[Upload] Fichier audio supprim\u{00e9}: \(url.lastPathComponent)")
    }
    
    // MARK: - Retry Logic (factorisé)
    
    /// Tente l'upload avec retry automatique (backoff exponentiel).
    /// Logique de retry partagée entre uploadAudio et uploadRecoveredAudio.
    private func uploadWithRetry(
        webhookURL: URL,
        audioFileURL: URL,
        fields: [(String, String)],
        onProgress: ((Double) -> Void)?
    ) async throws {
        var lastError: UploadError?
        
        for attempt in 1...Self.maxRetries {
            do {
                // Reset progression à 0 au début de chaque tentative
                await MainActor.run { onProgress?(0) }
                
                try await performUpload(
                    webhookURL: webhookURL,
                    audioFileURL: audioFileURL,
                    fields: fields,
                    onProgress: onProgress
                )
                
                if attempt > 1 {
                    print("[Upload] Upload r\u{00e9}ussi \u{00e0} la tentative \(attempt)")
                } else {
                    print("[Upload] Upload r\u{00e9}ussi")
                }
                return
                
            } catch let error as UploadError {
                lastError = error
                print("[Upload] Tentative \(attempt)/\(Self.maxRetries) \u{00e9}chou\u{00e9}e: \(error.localizedDescription ?? "unknown")")
                
                guard error.isRetryable, attempt < Self.maxRetries else { break }
                
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                print("[Upload] Retry dans \(delay / 1_000_000_000)s...")
                try? await Task.sleep(nanoseconds: delay)
                
            } catch {
                let nsError = error as NSError
                lastError = .networkError("\(nsError.localizedDescription) (code \(nsError.code))")
                print("[Upload] Tentative \(attempt)/\(Self.maxRetries) - Erreur r\u{00e9}seau: \(error.localizedDescription)")
                
                guard attempt < Self.maxRetries else { break }
                
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                print("[Upload] Retry dans \(delay / 1_000_000_000)s...")
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        
        throw UploadError.allRetriesFailed(lastError?.localizedDescription ?? "Erreur inconnue")
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
        print("[Upload] Fichier audio valid\u{00e9}: \(String(format: "%.1f", sizeMB)) MB")
    }
    
    // MARK: - Single Upload Attempt (streaming + progress)
    
    private func performUpload(
        webhookURL: URL,
        audioFileURL: URL,
        fields: [(String, String)],
        onProgress: ((Double) -> Void)?
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
        // Body size sanity check (cohérence avec iPhone/Watch)
        let bodyAttrs = try? FileManager.default.attributesOfItem(atPath: tempBodyURL.path)
        let bodySize = bodyAttrs?[.size] as? Int ?? 0
        let audioAttrs = try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)
        let audioSize = audioAttrs?[.size] as? Int ?? 0
        if bodySize <= audioSize {
            print("[Upload] ⚠️ Body multipart (\(bodySize) octets) <= audio (\(audioSize) octets) — fichier potentiellement corrompu")
            throw UploadError.networkError("Body multipart corrompu (\(bodySize) <= \(audioSize))")
        }
        print("[Upload] Body multipart validé: \(bodySize) octets (audio: \(audioSize) octets)")
        
        // Upload avec delegate pour la progression
        let delegate = UploadProgressDelegate()
        delegate.onProgress = onProgress
        
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        
        let (responseData, response) = try await session.upload(for: request, fromFile: tempBodyURL)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.networkError("R\u{00e9}ponse HTTP invalide")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "No body"
            throw UploadError.serverError(statusCode: httpResponse.statusCode, body: body)
        }
        
        // Marquer 100% à la fin
        await MainActor.run { onProgress?(1.0) }
        print("[Upload] Upload r\u{00e9}ussi (HTTP \(httpResponse.statusCode))")
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
