//
//  CalendarEvent.swift
//  TaskFlowMac
//
//  Modèle d'événement calendrier.
//  Identique au modèle iPhone (WidgetModels.swift) pour compatibilité.
//

import Foundation

struct CalendarEvent: Codable, Identifiable {
    let notionPageId: String
    let Titre: String
    let DateStart: String
    let DateEnd: String?
    let Horaire: String?
    let Lieu: String?
    let Calendrier: String
    let url: String?
    let participants: [Participant]?
    let allParticipants: [Participant]?
    let participantCount: Int?
    let resume: String?
    
    var id: String { notionPageId }
    
    // MARK: - Computed
    
    var displayTitle: String {
        Titre.isEmpty ? "Sans titre" : Titre
    }
    
    var isPersonal: Bool {
        Calendrier == "Personnel"
    }
    
    var isPrivate: Bool {
        Calendrier == "Privé"
    }
    
    /// Date de début parsée
    var startDate: Date? {
        Self.parseDate(DateStart)
    }
    
    /// Date de fin parsée
    var endDate: Date? {
        guard let dateEnd = DateEnd else { return nil }
        return Self.parseDate(dateEnd)
    }
    
    /// Durée en minutes
    var durationMinutes: Int? {
        guard let start = startDate, let end = endDate else { return nil }
        return Int(end.timeIntervalSince(start) / 60)
    }
    
    /// Plage horaire formatée (ex: "14h00 – 15h30")
    var timeRange: String {
        guard let start = startDate else { return Horaire ?? "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "H'h'mm"
        
        var result = formatter.string(from: start)
        if let end = endDate {
            result += " – " + formatter.string(from: end)
        }
        return result
    }
    
    /// Noms des participants (sans self)
    var participantNames: String {
        guard let participants, !participants.isEmpty else { return "" }
        return participants.map { $0.name }.joined(separator: ", ")
    }
    
    // MARK: - Date Parsing
    
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
    private static func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? isoFormatterNoFrac.date(from: string)
    }
}

// MARK: - Participant

struct Participant: Codable, Identifiable {
    let id: String
    let name: String
    let entreprise: String?
    let fonction: String?
}
