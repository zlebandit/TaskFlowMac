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
//  IMPORTANT : Le sample rate n'est pas fixé à l'avance.
//  macOS délivre généralement du 48000 Hz via ScreenCaptureKit.
//  Le AVAssetWriter est configuré dynamiquement au premier sample reçu
//  pour matcher exactement le format source.
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
    private var writerIsReady = false
    private var sampleCount = 0
    private var appendFailCount = 0
    private var totalFrameCount: Int64 = 0
    private var nonSilentSampleCount = 0
    
    /// Queue dédiée pour recevoir les samples audio
    private let audioQueue = DispatchQueue(label: "com.taskflowmac.audiocapture", qos: .userInitiated)
    
    // MARK: - Public API
    
    /// Démarre la capture audio système et l'écriture en fichier M4A.
    /// - Returns: URL du fichier M4A (pas encore finalisé, sera complet après stop)
    func startCapture() async throws -> URL {
        guard !isCapturing else { throw AudioCaptureError.alreadyRecording }
        
        // 1. Vérifier la permission Screen Recording
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
        
        // 3. Configurer le stream
        let config = SCStreamConfiguration()
        
        // Audio : activé, exclure l'audio de notre propre app
        // On demande 48kHz stéréo (format natif macOS)
        config.capturesAudio = true
        config.sampleRate = 48000
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
        
        // 5. Préparer le AVAssetWriter (sans audioInput pour l'instant)
        // L'audioInput sera ajouté dynamiquement au premier sample
        // pour matcher le format exact délivré par ScreenCaptureKit
        try prepareAssetWriter(outputURL: fileURL)
        
        // 6. Créer et démarrer le stream
        let output = AudioStreamOutput(service: self)
        self.streamOutput = output
        
        let scStream = SCStream(filter: filter, configuration: config, delegate: output)
        
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: audioQueue)
        try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        
        self.stream = scStream
        self.isCapturing = true
        self.hasReceivedFirstSample = false
        self.writerIsReady = false
        self.sampleCount = 0
        self.appendFailCount = 0
        self.totalFrameCount = 0
        self.nonSilentSampleCount = 0
        
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
        
        let durationSec = Double(totalFrameCount) / 48000.0
        print("🎙️ Stream arrêté. Samples: \(sampleCount), frames: \(totalFrameCount) (~\(Int(durationSec))s), non-silence: \(nonSilentSampleCount)/\(sampleCount), appends failed: \(appendFailCount)")
        
        // 2. Finaliser l'écriture du fichier
        guard let writer = assetWriter else {
            throw AudioCaptureError.writerFailed("No asset writer")
        }
        
        // Si aucun sample n'a été reçu, on ne peut pas finaliser le writer
        if !hasReceivedFirstSample || !writerIsReady {
            print("🎙️ ⚠️ Aucun sample audio reçu — annulation du writer")
            audioInput?.markAsFinished()
            writer.cancelWriting()
            self.assetWriter = nil
            self.audioInput = nil
            
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
    
    /// Prépare le AVAssetWriter (sans audioInput — sera ajouté au premier sample)
    private func prepareAssetWriter(outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        let writer = try AVAssetWriter(url: outputURL, fileType: .m4a)
        self.assetWriter = writer
        
        print("🎙️ AVAssetWriter prêt (attente du premier sample pour détecter le format)")
    }
    
    /// Configure dynamiquement le AVAssetWriterInput au premier sample audio
    /// pour matcher exactement le format délivré par ScreenCaptureKit
    private func setupAudioInput(from sampleBuffer: CMSampleBuffer) -> Bool {
        guard let writer = assetWriter, writer.status != .writing || !writerIsReady else {
            return writerIsReady
        }
        
        // Détecter le format du sample
        var sampleRate: Double = 48000
        var channelCount: UInt32 = 2
        
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sampleRate = asbd.pointee.mSampleRate
            channelCount = asbd.pointee.mChannelsPerFrame
            print("🎙️ 🎵 Format détecté: \(sampleRate) Hz, \(channelCount) ch, \(asbd.pointee.mBitsPerChannel) bit, formatID: \(asbd.pointee.mFormatID)")
        } else {
            print("🎙️ ⚠️ Impossible de lire le format — utilisation des valeurs par défaut (48kHz stéréo)")
        }
        
        // Configurer l'AVAssetWriterInput avec le bon sample rate
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 128_000
        ]
        
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        
        guard writer.canAdd(input) else {
            print("🎙️ ❌ Cannot add audio input to writer")
            return false
        }
        
        writer.add(input)
        
        guard writer.startWriting() else {
            print("🎙️ ❌ Writer startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
            return false
        }
        
        // Démarrer la session au timestamp du premier sample
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: pts)
        
        self.audioInput = input
        self.writerIsReady = true
        
        print("🎙️ ✅ AVAssetWriter configuré dynamiquement: AAC \(Int(sampleRate)) Hz \(channelCount) ch 128 kbps")
        return true
    }
    
    /// Appelée par AudioStreamOutput quand un sample audio arrive
    fileprivate func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturing, let _ = assetWriter else {
            return
        }
        
        // Premier sample : configurer dynamiquement le writer
        if !hasReceivedFirstSample {
            hasReceivedFirstSample = true
            if !setupAudioInput(from: sampleBuffer) {
                print("🎙️ ❌ Échec configuration writer au premier sample")
                return
            }
        }
        
        guard writerIsReady,
              let writer = assetWriter,
              let input = audioInput,
              writer.status == .writing else {
            return
        }
        
        guard input.isReadyForMoreMediaData else {
            return
        }
        
        // Mesurer le niveau audio pour diagnostic
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        totalFrameCount += Int64(frameCount)
        
        // Vérifier si le buffer contient du vrai audio (pas du silence)
        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var lengthAtOffset: Int = 0
            var totalLength: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            if status == noErr, let ptr = dataPointer, totalLength > 0 {
                // Les samples sont en Float32 (LPCM) — calculer le max absolu
                let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float32.self, capacity: totalLength / 4)
                let floatCount = totalLength / 4
                var maxAbs: Float32 = 0
                for i in 0..<min(floatCount, 1024) {
                    let absVal = abs(floatPtr[i])
                    if absVal > maxAbs { maxAbs = absVal }
                }
                if maxAbs > 0.001 { // Seuil au-dessus du bruit de fond
                    nonSilentSampleCount += 1
                }
            }
        }
        
        // Écrire le sample
        if input.append(sampleBuffer) {
            sampleCount += 1
            if sampleCount % 500 == 0 {
                let durationSec = Double(totalFrameCount) / 48000.0
                print("🎙️ 📝 \(sampleCount) samples (\(totalFrameCount) frames, ~\(Int(durationSec))s) — audio non-silence: \(nonSilentSampleCount)/\(sampleCount)")
            }
        } else {
            appendFailCount += 1
            if appendFailCount <= 5 {
                print("🎙️ ⚠️ Échec append sample #\(sampleCount + 1) — writer status: \(assetWriter?.status.rawValue ?? -1), error: \(assetWriter?.error?.localizedDescription ?? "none")")
            }
        }
    }
    
    /// Appelée par AudioStreamOutput quand un sample vidéo arrive (ignoré)
    fileprivate func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        if sampleCount == 0 && !hasReceivedFirstSample {
            print("🎙️ 📺 Sample vidéo reçu (stream actif, en attente d'audio...)")
        }
    }
}

// MARK: - SCStreamOutput + SCStreamDelegate

private class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    
    let service: AudioCaptureService
    
    init(service: AudioCaptureService) {
        self.service = service
    }
    
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
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("🎙️ ❌ Stream arrêté avec erreur: \(error.localizedDescription)")
    }
}
