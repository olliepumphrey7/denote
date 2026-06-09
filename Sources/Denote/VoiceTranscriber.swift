import AVFoundation
import Foundation
@preconcurrency import WhisperKit

@MainActor
final class VoiceTranscriber: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    var onStateChanged: ((State) -> Void)?
    var onTranscript: ((String) -> Void)?

    private var state: State = .idle {
        didSet { onStateChanged?(state) }
    }
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var whisperKit: WhisperKit?

    func toggleRecording() {
        switch state {
        case .idle, .failed:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        Task {
            let granted = await requestMicrophoneAccess()
            guard granted else {
                state = .failed("Microphone access denied")
                return
            }

            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("denote-transcription-\(UUID().uuidString)")
                    .appendingPathExtension("m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.delegate = self
                recorder.isMeteringEnabled = false
                recorder.prepareToRecord()
                guard recorder.record() else {
                    state = .failed("Could not start recording")
                    return
                }
                self.recorder = recorder
                recordingURL = url
                state = .recording
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil

        guard let recordingURL else {
            state = .idle
            return
        }
        self.recordingURL = nil
        transcribe(url: recordingURL)
    }

    private func transcribe(url: URL) {
        state = .transcribing
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                if whisperKit == nil {
                    whisperKit = try await WhisperKit(WhisperKitConfig(model: "small"))
                }
                guard let whisperKit else {
                    state = .failed("WhisperKit failed to load")
                    return
                }
                let results = try await whisperKit.transcribe(audioPath: url.path)
                let text = results
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if text.isEmpty {
                    state = .idle
                    return
                }
                onTranscript?(text)
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
