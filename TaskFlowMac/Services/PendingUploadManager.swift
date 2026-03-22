//
//  PendingUploadManager.swift
//  TaskFlowMac
//
//  Gestionnaire des fichiers audio en attente d'upload.
//  Pattern sidecar JSON : chaque fichier .m4a est accompagné d'un .json
//  contenant les métadonnées nécessaires à l'upload.
//
//  Avantages par rapport à UserDefaults seul :
//    - Supporte N fichiers en attente (pas seulement le dernier)
//    - Les métadonnées survivent aux crashes, reinstalls, mises à jour
//    - Source de vérité = filesystem (pas de désync possible)
//    - Nettoyage simple : supprimer le .m4a supprime aussi le .json
//
//  Flux :
//    1. Enregistrement terminé → saveSidecar() crée le .json à côté du .m4a
//    2. Upload réussi → deletePending() supprime .m4a + .json
//    3. Upload échoué → recordFailure() incrémente le compteur dans le .json
//    4. Au lancement → scanPendingUploads() scanne le dossier, lit les sidecars
//    5. Retry → uploadPending() retente l'upload avec les métadonnées du sidecar
//

import Foundation

// MARK: - Upload Metadata (sidecar JSON)

/// Métadonnées persistées dans le fichier sidecar JSON.
/// Contient tout le nécessaire pour retenter l'upload sans UserDefaults.
struct UploadMetadata: Codable {
    var eventId: String
    var eventTitle: String
    var notionPageId: String
    var startDate: String
    var endDate: String
    var participantsJSON: String
    var eventDate: String
    
    // Tracking des échecs
    var failureCount: Int
    var lastError: String?
    var lastFailureDate: Date?
    
    /// Crée les métadonnées initiales
    init(
        eventId: String = "",
        eventTitle: String = "Enregistrement libre",
        notionPageId: String = "",
        startDate: String = "",
        endDate: String = "",
        participantsJSON: String = "[]",
        eventDate: String? = nil
    ) {
        self.eventId = eventId
        self.eventTitle = eventTitle
        self.notionPageId = notionPageId
        self.startDate = startDate
        self.endDate = endDate
        self.participantsJSON = participantsJSON
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        self.eventDate = eventDate ?? formatter.string(from: Date())
        
        self.failureCount = 0
        self.lastError = nil
        self.lastFailureDate = nil
    }
}

// MARK: - Pending Upload Info

/// Représente un fichier audio en attente avec ses métadonnées sidecar.
struct PendingUploadInfo: Identifiable {
    let id: String              // nom du fichier .m4a
    let audioURL: URL           // chemin complet du .m4a
    let sidecarURL: URL         // chemin complet du .json
    let metadata: UploadMetadata?
    let fileSizeMB: Double
    let fileDate: Date
    
    /// True si le sidecar existe et contient un événement assigné
    var isAssigned: Bool {
        guard let meta = metadata else { return false }
        return !meta.notionPageId.isEmpty
    }
    
    /// Label affiché dans la UI
    var displayLabel: String {
        if let meta = metadata, !meta.eventTitle.isEmpty, meta.eventTitle != "Enregistrement libre" {
            var label = "\(meta.eventTitle) — \(String(format: "%.1f", fileSizeMB)) MB"
            if meta.failureCount > 0 {
                label += " (\(meta.failureCount) échec\(meta.failureCount > 1 ? "s" : ""))"
            }
            return label
        }
        // Extraire date/heure du nom de fichier
        let name = id.replacingOccurrences(of: "recording_", with: "").replacingOccurrences(of: ".m4a", with: "")
        let parts = name.split(separator: "_")
        if parts.count >= 2 {
            let datePart = String(parts[0])
            let timePart = String(parts[1]).replacingOccurrences(of: "-", with: ":")
            return "Enreg. \(datePart) \(timePart) — \(String(format: "%.1f", fileSizeMB)) MB"
        }
        return "\(id) — \(String(format: "%.1f", fileSizeMB)) MB"
    }
}

// MARK: - PendingUploadManager

struct PendingUploadManager {
    
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    
    // MARK: - Sidecar Path
    
    /// Retourne l'URL du sidecar JSON pour un fichier audio donné.
    /// recording_2026-03-08_14-30-00.m4a → recording_2026-03-08_14-30-00.json
    static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("json")
    }
    
    // MARK: - Save Sidecar
    
    /// Crée ou met à jour le fichier sidecar JSON à côté du .m4a.
    @discardableResult
    static func saveSidecar(for audioURL: URL, metadata: UploadMetadata) -> Bool {
        let url = sidecarURL(for: audioURL)
        do {
            let data = try encoder.encode(metadata)
            try data.write(to: url, options: .atomic)
            print("🎙️ 💾 Sidecar sauvé: \(url.lastPathComponent)")
            return true
        } catch {
            print("🎙️ ❌ Erreur sauvegarde sidecar: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Load Sidecar
    
    /// Lit les métadonnées depuis le fichier sidecar JSON.
    static func loadSidecar(for audioURL: URL) -> UploadMetadata? {
        let url = sidecarURL(for: audioURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(UploadMetadata.self, from: data)
    }
    
    // MARK: - Record Failure
    
    /// Incrémente le compteur d'échecs dans le sidecar après un upload raté.
    static func recordFailure(for audioURL: URL, error: String) {
        var metadata = loadSidecar(for: audioURL) ?? UploadMetadata()
        metadata.failureCount += 1
        metadata.lastError = error
        metadata.lastFailureDate = Date()
        saveSidecar(for: audioURL, metadata: metadata)
        print("🎙️ ⚠️ Échec #\(metadata.failureCount) enregistré pour \(audioURL.lastPathComponent): \(error)")
    }
    
    // MARK: - Assign Event
    
    /// Met à jour le sidecar avec les informations d'un événement.
    static func assignEvent(
        for audioURL: URL,
        eventId: String,
        eventTitle: String,
        notionPageId: String,
        participantsJSON: String = "[]"
    ) {
        var metadata = loadSidecar(for: audioURL) ?? UploadMetadata()
        metadata.eventId = eventId
        metadata.eventTitle = eventTitle
        metadata.notionPageId = notionPageId
        metadata.participantsJSON = participantsJSON
        saveSidecar(for: audioURL, metadata: metadata)
        print("🎙️ 📎 Événement assigné dans sidecar: \(eventTitle)")
    }
    
    // MARK: - Delete Pending
    
    /// Supprime le fichier audio ET son sidecar JSON.
    static func deletePending(audioURL: URL) {
        let sidecar = sidecarURL(for: audioURL)
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: sidecar)
        print("🎙️ 🗑️ Supprimé: \(audioURL.lastPathComponent) + sidecar")
    }
    
    // MARK: - Scan Pending Uploads
    
    /// Scanne le répertoire d'enregistrements et retourne tous les fichiers
    /// .m4a en attente d'upload, enrichis par leurs sidecars.
    /// Exclut le fichier en cours d'enregistrement (activeFilePath).
    static func scanPendingUploads(activeFilePath: String? = nil) -> [PendingUploadInfo] {
        let fm = FileManager.default
        let dir = Config.recordingsDirectory
        
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else { return [] }
        
        var results: [PendingUploadInfo] = []
        
        for file in files {
            guard file.pathExtension == "m4a" else { continue }
            
            // Exclure le fichier en cours d'enregistrement
            if file.path == activeFilePath { continue }
            
            // Vérifier la taille (> 10 KB)
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let size = (attrs?[.size] as? Int) ?? 0
            guard size > 10_240 else { continue }
            
            let creationDate = (attrs?[.creationDate] as? Date) ?? Date()
            let sidecar = sidecarURL(for: file)
            let metadata = loadSidecar(for: file)
            
            results.append(PendingUploadInfo(
                id: file.lastPathComponent,
                audioURL: file,
                sidecarURL: sidecar,
                metadata: metadata,
                fileSizeMB: Double(size) / 1_048_576,
                fileDate: creationDate
            ))
        }
        
        // Trier par date (plus récent en premier)
        return results.sorted { $0.fileDate > $1.fileDate }
    }
    
    // MARK: - Upload Pending
    
    /// Tente l'upload d'un fichier en attente. Retourne true si succès.
    static func uploadPending(_ pending: PendingUploadInfo) async -> Bool {
        guard let metadata = pending.metadata, pending.isAssigned else {
            print("🎙️ ⚠️ Pas de métadonnées ou événement non assigné pour \(pending.id)")
            return false
        }
        
        let uploadService = UploadService()
        
        do {
            try await uploadService.uploadRecoveredAudio(
                fileURL: pending.audioURL,
                eventTitle: metadata.eventTitle,
                notionPageId: metadata.notionPageId,
                eventDate: metadata.eventDate,
                startDate: metadata.startDate,
                endDate: metadata.endDate,
                participantsJSON: metadata.participantsJSON
            )
            
            // Succès → supprimer les fichiers
            deletePending(audioURL: pending.audioURL)
            print("🎙️ ✅ Upload pending réussi: \(metadata.eventTitle)")
            return true
            
        } catch {
            // Échec → enregistrer dans le sidecar
            recordFailure(for: pending.audioURL, error: error.localizedDescription)
            return false
        }
    }
    
    // MARK: - Migrate from UserDefaults
    
    /// Migration one-shot : si des métadonnées existent dans UserDefaults
    /// mais pas de sidecar JSON, créer le sidecar.
    /// À appeler une seule fois au lancement.
    static func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        
        guard defaults.bool(forKey: "recording.isActive"),
              let audioFilePath = defaults.string(forKey: "recording.audioFilePath") else {
            return
        }
        
        let audioURL = URL(fileURLWithPath: audioFilePath)
        
        // Vérifier que le fichier audio existe
        guard FileManager.default.fileExists(atPath: audioFilePath) else {
            print("🎙️ ⚠️ Migration: fichier audio disparu, nettoyage UserDefaults")
            clearUserDefaults()
            return
        }
        
        // Si un sidecar existe déjà, pas besoin de migrer
        if loadSidecar(for: audioURL) != nil {
            print("🎙️ ℹ️ Migration: sidecar déjà existant, skip")
            clearUserDefaults()
            return
        }
        
        // Créer le sidecar depuis UserDefaults
        let metadata = UploadMetadata(
            eventId: defaults.string(forKey: "recording.eventId") ?? "",
            eventTitle: defaults.string(forKey: "recording.eventTitle") ?? "Enregistrement libre",
            notionPageId: defaults.string(forKey: "recording.notionPageId") ?? "",
            startDate: defaults.string(forKey: "recording.startDate") ?? "",
            endDate: defaults.string(forKey: "recording.endDate") ?? Config.isoFormatter.string(from: Date()),
            participantsJSON: defaults.string(forKey: "recording.participantsJSON") ?? "[]"
        )
        
        if saveSidecar(for: audioURL, metadata: metadata) {
            print("🎙️ ✅ Migration UserDefaults → sidecar réussie: \(audioURL.lastPathComponent)")
            clearUserDefaults()
        }
    }
    
    /// Nettoie les clés UserDefaults de l'ancien système
    private static func clearUserDefaults() {
        let keys = [
            "recording.eventId", "recording.eventTitle", "recording.notionPageId",
            "recording.audioFilePath", "recording.startDate", "recording.endDate",
            "recording.participantsJSON", "recording.isActive"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
