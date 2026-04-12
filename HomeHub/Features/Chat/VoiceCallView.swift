import SwiftUI

struct VoiceCallView: View {
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var conversations: ConversationService
    @StateObject private var voiceService = VoiceService()
    
    @State private var waveformScale: CGFloat = 1.0
    @State private var authorizationStatus: Bool = false
    @State private var processingCall: Bool = false
    
    var body: some View {
        ZStack {
            HHTheme.canvas.ignoresSafeArea()
            
            VStack(spacing: HHTheme.spaceXL) {
                // Header
                HStack {
                    Spacer()
                    Button {
                        hangUp()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(HHTheme.textSecondary)
                    }
                }
                .padding()
                
                Spacer()
                
                // Visualization
                ZStack {
                    Circle()
                        .fill(voiceService.isSpeaking ? HHTheme.accent.opacity(0.2) : (voiceService.isListening ? HHTheme.success.opacity(0.2) : HHTheme.stroke))
                        .frame(width: 200, height: 200)
                        .scaleEffect(waveformScale)
                        .animation(
                            (voiceService.isSpeaking || voiceService.isListening)
                            ? Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .default,
                            value: voiceService.isSpeaking || voiceService.isListening
                        )
                    
                    Circle()
                        .fill(voiceService.isSpeaking ? HHTheme.accent : (voiceService.isListening ? HHTheme.success : HHTheme.textSecondary))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: voiceService.isSpeaking ? "waveform" : (voiceService.isListening ? "mic.fill" : "mic.slash.fill"))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(HHTheme.surface)
                }
                
                Spacer()
                
                // Status Text
                VStack(spacing: 8) {
                    if processingCall {
                        Text("Zpracovávám...")
                            .font(HHTheme.body)
                            .foregroundColor(HHTheme.textSecondary)
                    } else if voiceService.isListening {
                        Text("Poslouchám...")
                            .font(HHTheme.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(HHTheme.success)
                        
                        Text(voiceService.transcription)
                            .font(HHTheme.body)
                            .foregroundColor(HHTheme.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .lineLimit(3)
                    } else if voiceService.isSpeaking {
                        Text("Asistent mluví...")
                            .font(HHTheme.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(HHTheme.accent)
                    } else {
                        Text("Dotkněte se pro mluvení")
                            .font(HHTheme.body)
                            .foregroundColor(HHTheme.textSecondary)
                    }
                }
                .frame(height: 100)
                
                // Controls
                HStack(spacing: 40) {
                    Button(action: toggleMicrophone) {
                        Image(systemName: voiceService.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .frame(width: 72, height: 72)
                            .background(voiceService.isListening ? HHTheme.danger : HHTheme.accent)
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            Task {
                authorizationStatus = await voiceService.requestAuthorization()
                if authorizationStatus {
                    // Automatically start listening if desired
                    toggleMicrophone()
                }
            }
        }
        .onDisappear {
            hangUp()
        }
        .onChange(of: conversations.messages(in: conversationID).last?.content) { _, newValue in
            // Basic hook to read the incoming streaming text in chunks.
            // A more robust implementation would hook into ConversationService stream directly
            // or use punctuated boundaries to read sentences aloud seamlessly.
            guard let msg = conversations.messages(in: conversationID).last,
                  msg.role == .assistant,
                  msg.status == .complete, // Read the whole thing at the end for simplicity in this V1
                  !processingCall else {
                return
            }
            
            voiceService.speak(msg.content)
        }
        .onChange(of: conversations.streamingConversationIDs.contains(conversationID)) { _, isStreaming in
            if isStreaming {
                processingCall = true
            } else {
                processingCall = false
            }
        }
    }
    
    private func toggleMicrophone() {
        if voiceService.isListening {
            voiceService.stopListening()
            let finalOutput = voiceService.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalOutput.isEmpty {
                conversations.send(userInput: finalOutput, in: conversationID)
            }
        } else {
            voiceService.stopSpeaking()
            do {
                try voiceService.startListening()
            } catch {
                print("Error starting microphone: \(error)")
            }
        }
    }
    
    private func hangUp() {
        if voiceService.isListening {
            voiceService.stopListening()
        }
        voiceService.stopSpeaking()
        dismiss()
    }
}
