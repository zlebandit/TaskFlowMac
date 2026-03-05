//
//  SyncService.swift
//  TaskFlowMac
//
//  Appel /taskflow-sync pour récupérer les réunions du jour.
//  Version simplifiée : on ne garde que le calendrier.
//

import Foundation

struct SyncService {
    
    /// Réponse complète du sync (on ne décode que calendar)
    struct SyncResponse: Decodable {
        let calendar: [CalendarEvent]
    }
    
    /// Fetch les réunions du jour
    func fetchMeetings() async throws -> [CalendarEvent] {
        guard let url = URL(string: Config.syncURL) else {
            throw SyncError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["source": "taskflow-mac"])
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SyncError.serverError
        }
        
        let decoded = try JSONDecoder().decode(SyncResponse.self, from: data)
        
        // Trier par DateStart
        return decoded.calendar.sorted { $0.DateStart < $1.DateStart }
    }
    
    enum SyncError: LocalizedError {
        case invalidURL
        case serverError
        
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "URL invalide"
            case .serverError: return "Erreur serveur"
            }
        }
    }
}
