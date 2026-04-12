import Foundation
import Speech
import AVFoundation
import SwiftUI
import Accelerate
#if canImport(WhisperKit)
import WhisperKit
#endif

@MainActor
final class VoiceService: ObservableObject {
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcription = ""
    @Published var error: Error?
    
    // Speech Recognition
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "cs-CZ"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // Text to Speech
    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechSynthesizerDelegate?
    
    // WhisperKit
    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var isWhisperLoaded = false
    #endif
    
    init() {
        speechDelegate = SpeechSynthesizerDelegate { [weak self] isSpeaking in
            DispatchQueue.main.async {
                self?.isSpeaking = isSpeaking
            }
        }
        synthesizer.delegate = speechDelegate
        
        // Ensure default locale fallback
        if speechRecognizer == nil {
            print("Warning: cs-CZ locale not supported for SFSpeechRecognizer on this device, falling back.")
        }
    }
    
    // MARK: - Speech to Text
    
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    func startListening() throws {
        guard !audioEngine.isRunning else { return }
        
        // Setup audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { fatalError("Unable to create request") }
        recognitionRequest.shouldReportPartialResults = true
        
        // Configure input node
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        var lastSpeechTime: Date = Date()
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.recognitionRequest?.append(buffer)
            
            // Calculate RMS power
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var rms: Float = 0.0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
            let dbPower = 20 * log10(rms)
            
            // Typical background noise is <-40dB, speech is usually >-20dB to -10dB.
            // Adjust threshold based on testing.
            let isMuted = dbPower < -35.0
            
            DispatchQueue.main.async {
                if !isMuted {
                    lastSpeechTime = Date()
                } else if Date().timeIntervalSince(lastSpeechTime) > 1.5 {
                    // 1.5 seconds of silence detected
                    self.stopListening()
                }
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        isListening = true
        transcription = ""
        
        let recognizer = speechRecognizer ?? SFSpeechRecognizer()!
        
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                DispatchQueue.main.async {
                    self.transcription = result.bestTranscription.formattedString
                }
            }
            
            if error != nil || (result?.isFinal ?? false) {
                self.stopListening()
            }
        }
    }
    
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        
        isListening = false
    }
    
    // MARK: - Text to Speech
    
    func speak(_ text: String, interrupt: Bool = false) {
        if interrupt { stopSpeaking() }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "cs-CZ") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to setup audio session for TTS: \(error)")
        }
        
        synthesizer.speak(utterance)
    }
    
    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

private class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onStateChange: (Bool) -> Void
    
    init(onStateChange: @escaping (Bool) -> Void) {
        self.onStateChange = onStateChange
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onStateChange(true)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onStateChange(false)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onStateChange(false)
    }
}
