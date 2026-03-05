//
//  AudioCaptureService.swift
//  TaskFlowMac
//
//  Capture audio système via ScreenCaptureKit + encodage M4A via AVAssetWriter.
//  Capture l'audio des apps de visio (Teams/Zoom/Meet) sans le micro.
//
//  Flux :
//    1. SCShareableContent → récupère le display principal
//    2. SCContentFilter → filtre sur le display entier (audio système)
//    3. SCStream → capture avec capturesAudio = true, pas de vidéo utile
//    4. AVAssetWriter → encode les CMSampleBuffer audio en fichier M4A (AAC)
//    5. stopCapture() → finalise le fichier et retourne l'URL
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Erreurs possibles lors de la capture audio
enum AudioCaptureError: LocalizedError {
    case noDisplayFound
    case streamCreationFailed
    case writerSetupFailed(String)
    case writerFailed(String)
    case notRecording
    case alreadyRecording
    case noAudioCaptured
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .noDisplayFound: return "Aucun écran trouvé pour la capture"
        case .streamCreationFailed: return "Impossible de créer le flux de capture"
        case .writerSetupFailed(let msg): return "Erreur config writer: \(msg)"
        case .writerFailed(let msg): return "Erreur écriture audio: \(msg)"
        case .notRecording: return "Aucun enregistrement en cours"
        case .alreadyRecording: return "Un enregistrement est déjà en cours"
        case .noAudioCaptured: return "Aucun audio capturé. Vérifie que du son système est en cours (Teams/Zoom/Meet) et que la permission Screen Recording est accordée."
        case .permissionDenied: return "Permission Screen Recording requise. Va dans Préférences Système > Confidentialité > Enregistrement de l'écran et autorise TaskFlowMac, puis relance l'app."
        }
    }
}

/// Service de capture audio système via ScreenCaptureKit
class AudioCaptureService: NSObject, @unchecked Sendable {
    
    // MARK: - State
    
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var isCapturing = false
    private var hasReceivedFirstSample = false
    private var sampleCount = 0
    
    /// Queue dédiée pour recevoir les samples audio
    private let audioQueue = DispatchQueue(label: "com.taskflowmac.audiocapture", qos: .userInitiated)
    
    // MARK: - Public API
    
    /// Démarre la capture audio système et l'écriture en fichier M4A.
    /// - Returns: URL du fichier M4A (pas encore finalisé, sera complet après stop)
    func startCapture() async throws -> URL {
        guard !isCapturing else { throw AudioCaptureError.alreadyRecording }
        
        // 1. Vérifier la permission Screen Recording
        // SCShareableContent.excludingDesktopWindows lance une erreur si pas autorisé
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("🎙️ Permission OK — \(content.displays.count) display(s), \(content.applications.count) app(s)")
        } catch {
            print("🎙️ ❌ Permission Screen Recording refusée: \(error.localizedDescription)")
            throw AudioCaptureError.permissionDenied
        }
        
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }
        
        print("🎙️ Display: \(display.width)x\(display.height)")
        
        // 2. Créer le filtre de contenu — display entier pour capturer tout l'audio système
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // 3. Configurer le stream — audio uniquement
        let config = SCStreamConfiguration()
        
        // Audio : activé, 44.1kHz stéréo, exclure l'audio de notre propre app
        config.capturesAudio = true
        config.sampleRate = 44100
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        
        // Vidéo : config minimale (ScreenCaptureKit exige un flux vidéo)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        config.queueDepth = 1
        config.showsCursor = false
        
        // 4. Préparer le fichier de sortie M4A
        let fileURL = try prepareOutputFile()
        self.outputURL = fileURL
        
        // 5. Configurer AVAssetWriter
        try setupAssetWriter(outputURL: fileURL)
        
        // 6. Créer et démarrer le stream
        // On garde une référence forte vers le streamOutput pour éviter qu'il soit libéré
        let output = AudioStreamOutput(service: self)
        self.streamOutput = output
        
        let scStream = SCStream(filter: filter, configuration: config, delegate: output)
        
        // Ajouter les outputs — audio ET screen (screen est obligatoire pour que l'audio fonctionne)
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: audioQueue)
        try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        
        self.stream = scStream
        self.isCapturing = true
        self.hasReceivedFirstSample = false
        self.sampleCount = 0
        
        try await scStream.startCapture()
        
        print("🎙️ ✅ Capture audio système démarrée → \(fileURL.lastPathComponent)")
        return fileURL
    }
    
    /// Arrête la capture et finalise le fichier M4A.
    /// - Returns: URL du fichier M4A finalisé
    func stopCapture() async throws -> URL {
        guard isCapturing, let stream = self.stream else {
            throw AudioCaptureError.notRecording
        }
        
        // 1. Arrêter le stream ScreenCaptureKit
        try await stream.stopCapture()
        self.stream = nil
        self.streamOutput = nil
        self.isCapturing = false
        
        print("🎙️ Stream arrêté. Samples audio reçus: \(sampleCount)")
        
        // 2. Finaliser l'écriture du fichier
        guard let writer = assetWriter else {
            throw AudioCaptureError.writerFailed("No asset writer")
        }
        
        // Si aucun sample n'a été reçu, on ne peut pas finaliser le writer
        if !hasReceivedFirstSample {
            print("🎙️ ⚠️ Aucun sample audio reçu — annulation du writer")
            audioInput?.markAsFinished()
            writer.cancelWriting()
            self.assetWriter = nil
            self.audioInput = nil
            
            // Supprimer le fichier vide
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            
            throw AudioCaptureError.noAudioCaptured
        }
        
        audioInput?.markAsFinished()
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        
        guard writer.status == .completed else {
            let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
            print("🎙️ ❌ Writer status: \(writer.status.rawValue), error: \(errorMsg)")
            throw AudioCaptureError.writerFailed(errorMsg)
        }
        
        // 3. Cleanup
        self.assetWriter = nil
        self.audioInput = nil
        
        guard let url = outputURL else {
            throw AudioCaptureError.writerFailed("No output URL")
        }
        
        // Vérifier la taille du fichier
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        print("🎙️ ✅ Fichier audio finalisé: \(url.lastPathComponent) (\(fileSize / 1024) KB, \(sampleCount) samples)")
        
        // Fichier trop petit = probablement pas d'audio réel
        if fileSize < 1024 {
            print("🎙️ ⚠️ Fichier audio trop petit (\(fileSize) bytes) — probablement pas d'audio capturé")
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.noAudioCaptured
        }
        
        return url
    }
    
    /// Annule la capture en cours sans sauvegarder
    func cancelCapture() async {
        if let stream = self.stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        isCapturing = false
        
        audioInput?.markAsFinished()
        assetWriter?.cancelWriting()
        assetWriter = nil
        audioInput = nil
        
        // Supprimer le fichier partiel
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        
        print("🎙️ ⚠️ Capture annulée (\(sampleCount) samples reçus)")
    }
    
    // MARK: - Private
    
    /// Prépare le dossier et le fichier de sortie
    private func prepareOutputFile() throws -> URL {
        let dir = Config.recordingsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "recording_\(timestamp).m4a"
        
        return dir.appendingPathComponent(filename)
    }
    
    /// Configure AVAssetWriter pour écrire de l'audio AAC en M4A
    private func setupAssetWriter(outputURL: URL) throws {
        // Supprimer un éventuel fichier existant
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        let writer = try AVAssetWriter(url: outputURL, fileType: .m4a)
        
        // Configuration audio AAC
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        
        guard writer.canAdd(input) else {
            throw AudioCaptureError.writerSetupFailed("Cannot add audio input to writer")
        }
        
        writer.add(input)
        
        guard writer.startWriting() else {
            let errorMsg = writer.error?.localizedDescription ?? "Unknown"
            throw AudioCaptureError.writerSetupFailed(errorMsg)
        }
        
        print("🎙️ AVAssetWriter prêt (AAC 44.1kHz stéréo 128kbps)")
        
        self.assetWriter = writer
        self.audioInput = input
    }
    
    /// Appelée par AudioStreamOutput quand un sample audio arrive
    fileprivate func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing,
              let writer = assetWriter,
              let input = audioInput else {
            return
        }
        
        // Vérifier le status du writer
        guard writer.status == .writing else {
            if writer.status == .failed {
                print("🎙️ ❌ Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
            return
        }
        
        guard input.isReadyForMoreMediaData else {
            // Le writer n'est pas prêt, on skip ce sample
            return
        }
        
        // Démarrer la session au premier sample
        if !hasReceivedFirstSample {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            hasReceivedFirstSample = true
            
            // Log le format audio reçu
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                print("🎙️ 🎵 Premier sample audio reçu — Format: \(asbd.pointee.mFormatID) \(asbd.pointee.mSampleRate)Hz \(asbd.pointee.mChannelsPerFrame)ch \(asbd.pointee.mBitsPerChannel)bit")
            } else {
                print("🎙️ 🎵 Premier sample audio reçu (format inconnu)")
            }
        }
        
        // Écrire le sample
        if input.append(sampleBuffer) {
            sampleCount += 1
            // Log périodique
            if sampleCount % 500 == 0 {
                print("🎙️ 📝 \(sampleCount) samples audio écrits")
            }
        } else {
            print("🎙️ ⚠️ Échec append sample #\(sampleCount + 1) — writer status: \(writer.status.rawValue)")
        }
    }
    
    /// Appelée par AudioStreamOutput quand un sample vidéo arrive (ignoré)
    fileprivate func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        // On ignore la vidéo, mais on log le premier pour confirmer que le stream fonctionne
        if sampleCount == 0 && !hasReceivedFirstSample {
            print("🎙️ 📺 Sample vidéo reçu (stream actif, en attente d'audio...)")
        }
    }
}

// MARK: - SCStreamOutput + SCStreamDelegate

/// Classe séparée pour recevoir les callbacks du stream
private class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    
    // Référence forte (pas weak) — le service est owner, pas de cycle car le service contrôle la durée de vie
    let service: AudioCaptureService
    
    init(service: AudioCaptureService) {
        self.service = service
    }
    
    // SCStreamOutput — reçoit les sample buffers
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            service.handleAudioSample(sampleBuffer)
        case .screen:
            service.handleScreenSample(sampleBuffer)
        @unknown default:
            break
        }
    }
    
    // SCStreamDelegate — gestion des erreurs
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("🎙️ ❌ Stream arrêté avec erreur: \(error.localizedDescription)")
    }
}
