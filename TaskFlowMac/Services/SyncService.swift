//
//  SyncService.swift
//  TaskFlowMac
//
//  Appel /taskflow-sync pour récupérer les réunions du jour.
//  Version simplifiée : on ne garde que le calendrier.
//  Retry automatique (3 tentatives : 1s → 3s → 5s).
//

import Foundation

struct SyncService {
    
    /// Réponse complète du sync (on ne décode que calendar)
    struct SyncResponse: Decodable {
        let calendar: [CalendarEvent]
    }
    
    private static let maxRetries = 3
    private static let retryDelays: [UInt64] = [
        1_000_000_000,  // 1s
        3_000_000_000,  // 3s
        5_000_000_000   // 5s
    ]
    
    /// Fetch les réunions du jour (avec retry automatique)
    func fetchMeetings() async throws -> [CalendarEvent] {
        guard let url = URL(string: Config.syncURL) else {
            throw SyncError.invalidURL
        }
        
        var lastError: Error?
        
        for attempt in 1...Self.maxRetries {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["source": "taskflow-mac"])
                request.timeoutInterval = 15
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw SyncError.serverError
                }
                
                let decoded = try JSONDecoder().decode(SyncResponse.self, from: data)
                
                if attempt > 1 {
                    print("\u{2705} Sync réussie à la tentative \(attempt)")
                }
                
                // Trier par DateStart
                return decoded.calendar.sorted { $0.DateStart < $1.DateStart }
                
            } catch {
                lastError = error
                print("\u{26a0}\u{fe0f} Sync tentative \(attempt)/\(Self.maxRetries) échouée: \(error.localizedDescription)")
                
                guard attempt < Self.maxRetries else { break }
                let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        
        throw lastError ?? SyncError.serverError
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
