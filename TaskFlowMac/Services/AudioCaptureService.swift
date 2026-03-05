//
//  AudioCaptureService.swift
//  TaskFlowMac
//
//  Capture audio microphone via AVAudioEngine + encodage M4A via AVAssetWriter.
//  Enregistre ce que captent les micros du Mac (réunion en salle).
//
//  Flux :
//    1. AVAudioEngine → tap sur l'entrée micro (input node)
//    2. AVAssetWriter → encode les PCM buffers en fichier M4A (AAC)
//    3. stopCapture() → finalise le fichier et retourne l'URL
//
//  Permissions requises :
//    - Microphone (NSMicrophoneUsageDescription dans Info.plist)
//    - com.apple.security.device.audio-input dans entitlements
//

import Foundation
import AVFoundation
import CoreMedia

/// Erreurs possibles lors de la capture audio
enum AudioCaptureError: LocalizedError {
    case writerSetupFailed(String)
    case writerFailed(String)
    case notRecording
    case alreadyRecording
    case noAudioCaptured
    case microphonePermissionDenied
    case noInputDevice
    
    var errorDescription: String? {
        switch self {
        case .writerSetupFailed(let msg): return "Erreur config writer: \(msg)"
        case .writerFailed(let msg): return "Erreur écriture audio: \(msg)"
        case .notRecording: return "Aucun enregistrement en cours"
        case .alreadyRecording: return "Un enregistrement est déjà en cours"
        case .noAudioCaptured: return "Aucun audio capturé. Vérifie que le micro est accessible."
        case .microphonePermissionDenied: return "Permission Microphone requise. Va dans Préférences Système > Confidentialité > Microphone et autorise TaskFlowMac, puis relance l'app."
        case .noInputDevice: return "Aucun périphérique d'entrée audio trouvé."
        }
    }
}

/// Service de capture audio microphone via AVAudioEngine
class AudioCaptureService: NSObject, @unchecked Sendable {
    
    // MARK: - State
    
    private var audioEngine: AVAudioEngine?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var isCapturing = false
    private var sampleCount = 0
    private var totalFrameCount: Int64 = 0
    private var nonSilentBufferCount = 0
    private var startTime: Date?
    
    /// Queue dédiée pour l'écriture audio
    private let writeQueue = DispatchQueue(label: "com.taskflowmac.audiowrite", qos: .userInitiated)
    
    // MARK: - Public API
    
    /// Démarre la capture audio microphone et l'écriture en fichier M4A.
    /// - Returns: URL du fichier M4A (pas encore finalisé, sera complet après stop)
    func startCapture() async throws -> URL {
        guard !isCapturing else { throw AudioCaptureError.alreadyRecording }
        
        // 1. Vérifier la permission microphone
        let permissionGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        
        guard permissionGranted else {
            print("🎙️ ❌ Permission Microphone refusée")
            throw AudioCaptureError.microphonePermissionDenied
        }
        
        print("🎙️ ✅ Permission Microphone OK")
        
        // 2. Configurer AVAudioEngine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("🎙️ ❌ Aucun périphérique d'entrée audio détecté")
            throw AudioCaptureError.noInputDevice
        }
        
        let sampleRate = inputFormat.sampleRate
        let channelCount = inputFormat.channelCount
        print("🎙️ 🎵 Micro détecté: \(sampleRate) Hz, \(channelCount) ch")
        
        // 3. Préparer le fichier de sortie M4A
        let fileURL = try prepareOutputFile()
        self.outputURL = fileURL
        
        // 4. Configurer AVAssetWriter avec AAC
        try setupAssetWriter(outputURL: fileURL, sampleRate: sampleRate, channelCount: channelCount)
        
        // 5. Reset compteurs
        self.sampleCount = 0
        self.totalFrameCount = 0
        self.nonSilentBufferCount = 0
        self.startTime = Date()
        self.isCapturing = true
        self.audioEngine = engine
        
        // 6. Installer le tap sur l'input node
        // Utiliser un buffer size de 4096 frames (~85ms à 48kHz)
        let bufferSize: AVAudioFrameCount = 4096
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
            self?.handleAudioBuffer(buffer, time: time)
        }
        
        // 7. Démarrer l'engine
        try engine.start()
        
        print("🎙️ ✅ Capture microphone démarrée → \(fileURL.lastPathComponent)")
        return fileURL
    }
    
    /// Arrête la capture et finalise le fichier M4A.
    /// - Returns: URL du fichier M4A finalisé
    func stopCapture() async throws -> URL {
        guard isCapturing, let engine = self.audioEngine else {
            throw AudioCaptureError.notRecording
        }
        
        // 1. Arrêter le tap et l'engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.audioEngine = nil
        self.isCapturing = false
        
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        print("🎙️ Capture arrêtée. Durée: ~\(Int(duration))s, buffers: \(sampleCount), frames: \(totalFrameCount), non-silence: \(nonSilentBufferCount)/\(sampleCount)")
        
        // 2. Finaliser l'écriture du fichier
        guard let writer = assetWriter, let input = audioInput else {
            throw AudioCaptureError.writerFailed("No asset writer")
        }
        
        if sampleCount == 0 {
            print("🎙️ ⚠️ Aucun buffer audio reçu — annulation du writer")
            input.markAsFinished()
            writer.cancelWriting()
            self.assetWriter = nil
            self.audioInput = nil
            
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            
            throw AudioCaptureError.noAudioCaptured
        }
        
        input.markAsFinished()
        
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
        print("🎙️ ✅ Fichier audio finalisé: \(url.lastPathComponent) (\(fileSize / 1024) KB, \(sampleCount) buffers, ~\(Int(duration))s)")
        
        if fileSize < 1024 {
            print("🎙️ ⚠️ Fichier audio trop petit (\(fileSize) bytes)")
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.noAudioCaptured
        }
        
        return url
    }
    
    /// Annule la capture en cours sans sauvegarder
    func cancelCapture() async {
        if let engine = self.audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        isCapturing = false
        
        audioInput?.markAsFinished()
        assetWriter?.cancelWriting()
        assetWriter = nil
        audioInput = nil
        
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        
        print("🎙️ ⚠️ Capture annulée (\(sampleCount) buffers reçus)")
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
    
    /// Configure le AVAssetWriter avec les paramètres audio AAC
    private func setupAssetWriter(outputURL: URL, sampleRate: Double, channelCount: UInt32) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        let writer = try AVAssetWriter(url: outputURL, fileType: .m4a)
        
        // Configurer l'output AAC
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 128_000
        ]
        
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        
        guard writer.canAdd(input) else {
            throw AudioCaptureError.writerSetupFailed("Cannot add audio input to writer")
        }
        
        writer.add(input)
        
        guard writer.startWriting() else {
            throw AudioCaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        
        // On démarre la session à 0 — les timestamps seront relatifs
        writer.startSession(atSourceTime: .zero)
        
        self.assetWriter = writer
        self.audioInput = input
        
        print("🎙️ AVAssetWriter configuré: AAC \(Int(sampleRate)) Hz \(channelCount) ch 128 kbps")
    }
    
    /// Traite un buffer audio du micro
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isCapturing,
              let writer = assetWriter,
              let input = audioInput,
              writer.status == .writing,
              input.isReadyForMoreMediaData else {
            return
        }
        
        let frameCount = Int64(buffer.frameLength)
        totalFrameCount += frameCount
        
        // Diagnostic: vérifier si le buffer contient du vrai audio
        if let channelData = buffer.floatChannelData {
            var maxAbs: Float = 0
            let count = Int(buffer.frameLength)
            for i in 0..<min(count, 1024) {
                let absVal = abs(channelData[0][i])
                if absVal > maxAbs { maxAbs = absVal }
            }
            if maxAbs > 0.001 {
                nonSilentBufferCount += 1
            }
        }
        
        // Convertir AVAudioPCMBuffer → CMSampleBuffer pour AVAssetWriter
        guard let sampleBuffer = createSampleBuffer(from: buffer, presentationTime: cmTime(from: time)) else {
            return
        }
        
        if input.append(sampleBuffer) {
            sampleCount += 1
            if sampleCount % 500 == 0 {
                let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                print("🎙️ 📝 \(sampleCount) buffers (~\(Int(elapsed))s) — non-silence: \(nonSilentBufferCount)/\(sampleCount)")
            }
        }
    }
    
    /// Convertit AVAudioTime en CMTime
    private func cmTime(from audioTime: AVAudioTime) -> CMTime {
        // Calculer le temps relatif depuis le début
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        return CMTime(seconds: elapsed, preferredTimescale: 48000)
    }
    
    /// Crée un CMSampleBuffer à partir d'un AVAudioPCMBuffer
    private func createSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let frameCount = pcmBuffer.frameLength
        let format = pcmBuffer.format
        let channels = Int(format.channelCount)
        let frames = Int(frameCount)
        
        guard let channelData = pcmBuffer.floatChannelData, frames > 0 else { return nil }
        
        // Interleaver les données (AVAudioEngine fournit du non-interleaved par défaut)
        let interleavedCount = frames * channels
        var interleavedData = [Float](repeating: 0, count: interleavedCount)
        
        if format.isInterleaved {
            // Copier directement
            memcpy(&interleavedData, channelData[0], interleavedCount * MemoryLayout<Float>.size)
        } else {
            for frame in 0..<frames {
                for ch in 0..<channels {
                    interleavedData[frame * channels + ch] = channelData[ch][frame]
                }
            }
        }
        
        let dataSize = interleavedCount * MemoryLayout<Float>.size
        
        // Créer le format description interleaved
        var asbd = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        
        var formatDescription: CMFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let fmtDesc = formatDescription else { return nil }
        
        // Créer le block buffer avec une copie des données
        var blockBuffer: CMBlockBuffer?
        let blockStatus = interleavedData.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        guard blockStatus == noErr, let block = blockBuffer else { return nil }
        
        // Copier les données dans le block buffer
        let copyStatus = interleavedData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        
        guard copyStatus == noErr else { return nil }
        
        // Créer le CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmtDesc,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }
}
