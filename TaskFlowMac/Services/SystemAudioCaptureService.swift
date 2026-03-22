//
//  SystemAudioCaptureService.swift
//  TaskFlowMac
//
//  Capture audio système via ScreenCaptureKit.
//  Stocke les samples dans un ring buffer thread-safe,
//  consommé par AudioCaptureService lors du mixage.
//
//  Design :
//    - SCStream avec capturesAudio = true, excludesCurrentProcessAudio = true
//    - Ring buffer circulaire de max 3 secondes
//    - Thread-safe via NSLock
//    - Graceful fallback : si ScreenCaptureKit échoue, on reste en mic-only
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Service de capture audio système via ScreenCaptureKit
@available(macOS 13.0, *)
class SystemAudioCaptureService: NSObject, @unchecked Sendable {
    
    // MARK: - State
    
    private var stream: SCStream?
    private(set) var isCapturing = false
    
    // MARK: - Ring Buffer
    
    /// Ring buffer circulaire pour stocker les samples audio système (Float interleaved)
    private var ringBuffer: [Float] = []
    private var ringWriteIndex = 0
    private var ringAvailableCount = 0
    private var ringCapacity = 0
    private let ringLock = NSLock()
    
    // MARK: - Format
    
    private(set) var sampleRate: Double = 48000
    private(set) var channelCount: Int = 1
    
    // MARK: - Public API
    
    /// Démarre la capture audio système.
    /// - Parameters:
    ///   - sampleRate: Sample rate à utiliser (doit correspondre au micro)
    ///   - channelCount: Nombre de canaux (doit correspondre au micro)
    func startCapture(sampleRate: Double, channelCount: Int) async throws {
        guard !isCapturing else { return }
        
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        
        // Capacité ring buffer : 3 secondes
        ringCapacity = Int(sampleRate) * channelCount * 3
        ringBuffer = [Float](repeating: 0, count: ringCapacity)
        ringWriteIndex = 0
        ringAvailableCount = 0
        
        // 1. Récupérer le contenu partageable
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            print("🔊 ❌ ScreenCaptureKit: impossible de récupérer le contenu partageable: \(error.localizedDescription)")
            throw error
        }
        
        // 2. Filtre : capturer tout le display principal
        guard let display = content.displays.first else {
            print("🔊 ❌ Aucun display trouvé")
            throw SystemAudioError.noDisplay
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // 3. Configuration stream : audio uniquement
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = channelCount
        
        // Désactiver la capture vidéo (on ne veut que l'audio)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps min
        config.showsCursor = false
        
        // 4. Créer et démarrer le stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.taskflowmac.systemaudio", qos: .userInteractive))
        
        do {
            try await stream.startCapture()
            self.stream = stream
            self.isCapturing = true
            print("🔊 ✅ Capture audio système démarrée (\(Int(sampleRate)) Hz, \(channelCount) ch)")
        } catch {
            print("🔊 ❌ Échec démarrage capture système: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Arrête la capture audio système
    func stopCapture() async {
        guard isCapturing, let stream = self.stream else { return }
        
        do {
            try await stream.stopCapture()
        } catch {
            print("🔊 ⚠️ Erreur arrêt stream: \(error.localizedDescription)")
        }
        
        self.stream = nil
        self.isCapturing = false
        
        ringLock.lock()
        ringAvailableCount = 0
        ringWriteIndex = 0
        ringLock.unlock()
        
        print("🔊 Capture audio système arrêtée")
    }
    
    /// Vide le ring buffer (appelé lors de pause/resume pour maintenir la sync)
    func flush() {
        ringLock.lock()
        ringAvailableCount = 0
        ringWriteIndex = 0
        ringLock.unlock()
        print("🔊 Ring buffer vidé (flush)")
    }
    
    /// Consomme des samples du ring buffer.
    /// - Parameter count: nombre de samples Float à lire
    /// - Returns: tableau de samples (peut être plus court que count si pas assez de données)
    func consumeSamples(count: Int) -> [Float]? {
        ringLock.lock()
        defer { ringLock.unlock() }
        
        guard ringAvailableCount > 0 else { return nil }
        
        let toRead = min(count, ringAvailableCount)
        var result = [Float](repeating: 0, count: toRead)
        
        // Calculer l'index de lecture
        let readIndex = (ringWriteIndex - ringAvailableCount + ringCapacity) % ringCapacity
        
        // Copier les données (gestion du wrap-around)
        let firstChunk = min(toRead, ringCapacity - readIndex)
        for i in 0..<firstChunk {
            result[i] = ringBuffer[readIndex + i]
        }
        if toRead > firstChunk {
            for i in 0..<(toRead - firstChunk) {
                result[firstChunk + i] = ringBuffer[i]
            }
        }
        
        ringAvailableCount -= toRead
        return result
    }
}

// MARK: - SCStreamOutput

@available(macOS 13.0, *)
extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStream.OutputType) {
        guard type == .audio else { return }
        
        // Extraire les données audio du CMSampleBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = [UInt8](repeating: 0, count: length)
        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
        guard status == noErr else { return }
        
        // Déterminer le format
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }
        
        // Convertir en Float samples
        let floatSamples: [Float]
        
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Déjà en Float
            floatSamples = data.withUnsafeBytes { rawBuffer in
                let floatBuffer = rawBuffer.bindMemory(to: Float.self)
                return Array(floatBuffer)
            }
        } else if asbd.mBitsPerChannel == 16 {
            // Int16 → Float
            floatSamples = data.withUnsafeBytes { rawBuffer in
                let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
                return int16Buffer.map { Float($0) / 32768.0 }
            }
        } else {
            // Format non supporté, ignorer
            return
        }
        
        guard !floatSamples.isEmpty else { return }
        
        // Écrire dans le ring buffer
        ringLock.lock()
        for sample in floatSamples {
            ringBuffer[ringWriteIndex] = sample
            ringWriteIndex = (ringWriteIndex + 1) % ringCapacity
        }
        ringAvailableCount = min(ringAvailableCount + floatSamples.count, ringCapacity)
        ringLock.unlock()
    }
}

// MARK: - SCStreamDelegate

@available(macOS 13.0, *)
extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("🔊 ⚠️ Stream arrêté avec erreur: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            self?.stream = nil
        }
    }
}

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case noDisplay
    case captureNotAvailable
    
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Aucun écran détecté pour la capture audio système"
        case .captureNotAvailable: return "ScreenCaptureKit non disponible"
        }
    }
}
