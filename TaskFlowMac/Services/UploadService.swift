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
//  Le workflow attend :
//    - audio: le fichier M4A (champ binaire nommé "audio")
//    - eventTitle: titre de la réunion
//    - notionPageId: ID de la page Notion de la réunion
//    - eventDate: date de l'événement
//    - startDate: date/heure de début ISO8601
//    - endDate: date/heure de fin ISO8601
//    - participants: JSON des participants [{id, name, entreprise, fonction}]
//    - source: "taskflow-mac"
//

import Foundation

/// Erreurs d'upload
enum UploadError: LocalizedError {
    case fileNotFound
    case invalidURL
    case serverError(statusCode: Int, body: String)
    case networkError(String)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "Fichier audio introuvable"
        case .invalidURL: return "URL d'upload invalide"
        case .serverError(let code, let body): return "Erreur serveur (\(code)): \(body)"
        case .networkError(let msg): return "Erreur réseau: \(msg)"
        }
    }
}

struct UploadService {
    
    /// Upload le fichier audio vers n8n pour transcription
    /// - Parameters:
    ///   - fileURL: URL du fichier M4A local
    ///   - event: la réunion associée (pour les métadonnées)
    func uploadAudio(fileURL: URL, event: CalendarEvent) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileNotFound
        }
        
        guard let url = URL(string: Config.transcribeURL) else {
            throw UploadError.invalidURL
        }
        
        // Lire le fichier audio
        let audioData = try Data(contentsOf: fileURL)
        
        // Construire le multipart
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        
        // Champ : eventTitle (nom attendu par le workflow n8n)
        body.appendMultipartField(name: "eventTitle", value: event.displayTitle, boundary: boundary)
        
        // Champ : notionPageId
        body.appendMultipartField(name: "notionPageId", value: event.notionPageId, boundary: boundary)
        
        // Champ : eventDate (date du jour formatée)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        body.appendMultipartField(name: "eventDate", value: dateFormatter.string(from: Date()), boundary: boundary)
        
        // Champ : startDate (ISO8601)
        body.appendMultipartField(name: "startDate", value: event.DateStart, boundary: boundary)
        
        // Champ : endDate (ISO8601)
        if let dateEnd = event.DateEnd {
            body.appendMultipartField(name: "endDate", value: dateEnd, boundary: boundary)
        }
        
        // Champ : participants (JSON)
        if let participants = event.allParticipants ?? event.participants {
            if let jsonData = try? JSONEncoder().encode(participants),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                body.appendMultipartField(name: "participants", value: jsonString, boundary: boundary)
            }
        }
        
        // Champ : source
        body.appendMultipartField(name: "source", value: "taskflow-mac", boundary: boundary)
        
        // Fichier audio — IMPORTANT: le champ doit s'appeler "audio" (pas "file")
        // Le workflow n8n cherche binaryData.audio
        body.appendMultipartFile(
            name: "audio",
            filename: fileURL.lastPathComponent,
            mimeType: "audio/mp4",
            data: audioData,
            boundary: boundary
        )
        
        // Fin du multipart
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        // Construire la requête
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120 // 2 min pour les gros fichiers
        
        print("🎙️ Upload en cours... (\(audioData.count / 1024) KB)")
        
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UploadError.networkError("Réponse invalide")
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: responseData, encoding: .utf8) ?? "No body"
                throw UploadError.serverError(statusCode: httpResponse.statusCode, body: body)
            }
            
            print("🎙️ ✅ Upload réussi (HTTP \(httpResponse.statusCode))")
            
        } catch let error as UploadError {
            throw error
        } catch {
            throw UploadError.networkError(error.localizedDescription)
        }
    }
    
    /// Supprime le fichier audio local après upload réussi
    func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        print("🎙️ 🗑️ Fichier temporaire supprimé: \(url.lastPathComponent)")
    }
}

// MARK: - Data Multipart Helpers

private extension Data {
    
    /// Ajoute un champ texte au body multipart
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        let field = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        self.append(field.data(using: .utf8)!)
    }
    
    /// Ajoute un fichier au body multipart
    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        self.append(header.data(using: .utf8)!)
        self.append(data)
        self.append("\r\n".data(using: .utf8)!)
    }
}
