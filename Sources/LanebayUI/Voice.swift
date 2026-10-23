import AVFoundation
import AppKit
import Foundation
import Observation
import Speech

@MainActor
public protocol PushToTalkRecognizing {
  var isRecording: Bool { get }
  func startRecognition() async throws
  func stopRecognition() async throws -> String
}

@MainActor
public protocol VoiceStatusSpeaking {
  func speakShortStatus(_ text: String)
}

@MainActor
public struct SilentVoiceStatusSpeaker: VoiceStatusSpeaking {
  public init() {}
  public func speakShortStatus(_ text: String) {}
}

public enum VoiceRecognitionError: LocalizedError {
  case speechAuthorizationDenied
  case microphoneAuthorizationDenied
  case recognizerUnavailable
  case onDeviceRecognitionUnavailable
  case engineFailure(String)

  public var errorDescription: String? {
    switch self {
    case .speechAuthorizationDenied:
      "Speech recognition permission was denied."
    case .microphoneAuthorizationDenied:
      "Microphone permission was denied."
    case .recognizerUnavailable:
      "Speech recognizer is unavailable."
    case .onDeviceRecognitionUnavailable:
      "On-device speech recognition is not available on this Mac/locale."
    case let .engineFailure(message):
      "Voice recognition failed: \(message)"
    }
  }
}

@MainActor
public final class AppleOnDeviceSpeechRecognizer: PushToTalkRecognizing {
  public private(set) var isRecording = false

  private let locale: Locale
  private let audioEngine: AVAudioEngine
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var latestTranscript = ""
  private var finalContinuation: CheckedContinuation<String, Error>?

  public init(locale: Locale = .current, audioEngine: AVAudioEngine = AVAudioEngine()) {
    self.locale = locale
    self.audioEngine = audioEngine
  }

  public func startRecognition() async throws {
    guard !isRecording else { return }
    guard await Self.requestSpeechAuthorization() else { throw VoiceRecognitionError.speechAuthorizationDenied }
    guard await Self.requestMicrophoneAuthorization() else { throw VoiceRecognitionError.microphoneAuthorizationDenied }
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw VoiceRecognitionError.recognizerUnavailable
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw VoiceRecognitionError.onDeviceRecognitionUnavailable
    }

    latestTranscript = ""
    finalContinuation = nil

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    recognitionRequest = request

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        self.latestTranscript = result.bestTranscription.formattedString
        if result.isFinal, let continuation = self.finalContinuation {
          self.finalContinuation = nil
          continuation.resume(returning: self.latestTranscript)
        }
      }
      if let error, let continuation = self.finalContinuation {
        self.finalContinuation = nil
        continuation.resume(throwing: error)
      }
    }

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      cleanupRecordingState()
      throw VoiceRecognitionError.engineFailure(error.localizedDescription)
    }
    isRecording = true
  }

  public func stopRecognition() async throws -> String {
    guard isRecording else { return latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines) }
    isRecording = false
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()

    let transcript: String
    do {
      transcript = try await withCheckedThrowingContinuation { continuation in
        if !latestTranscript.isEmpty {
          // Return partial transcript immediately if final result does not arrive.
          finalContinuation = continuation
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if let pending = self.finalContinuation {
              self.finalContinuation = nil
              pending.resume(returning: self.latestTranscript)
            }
          }
        } else {
          finalContinuation = continuation
        }
      }
    } catch {
      cleanupRecordingState()
      throw VoiceRecognitionError.engineFailure(error.localizedDescription)
    }

    cleanupRecordingState()
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func cleanupRecordingState() {
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    finalContinuation = nil
  }

  private static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  private static func requestMicrophoneAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}

@MainActor
public final class AppleVoiceStatusSpeaker: VoiceStatusSpeaking {
  private let synthesizer: AVSpeechSynthesizer

  public init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
    self.synthesizer = synthesizer
  }

  public func speakShortStatus(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.volume = 0.8
    synthesizer.speak(utterance)
  }
}

@MainActor
@Observable
public final class VoiceCommandModel {
  public private(set) var isRecording = false
  public private(set) var statusMessage: String?
  public private(set) var errorMessage: String?
  public private(set) var latestTranscript: String?

  private let recognizer: PushToTalkRecognizing

  public init(
    recognizer: PushToTalkRecognizing = AppleOnDeviceSpeechRecognizer()
  ) {
    self.recognizer = recognizer
  }

  public func setPressed(_ pressed: Bool) async {
    if pressed {
      await begin()
    } else {
      await end()
    }
  }

  public func begin() async {
    guard !isRecording else { return }
    do {
      try await recognizer.startRecognition()
      isRecording = true
      statusMessage = "Listening..."
      errorMessage = nil
    } catch {
      isRecording = false
      statusMessage = nil
      errorMessage = error.localizedDescription
    }
  }

  public func end() async {
    guard isRecording else { return }
    do {
      let transcript = try await recognizer.stopRecognition()
      isRecording = false
      if transcript.isEmpty {
        statusMessage = "No speech captured."
      } else {
        statusMessage = "Transcript ready for review."
        latestTranscript = transcript
      }
      errorMessage = nil
    } catch {
      isRecording = false
      statusMessage = nil
      errorMessage = error.localizedDescription
    }
  }

  public func consumeTranscript() -> String? {
    defer { latestTranscript = nil }
    return latestTranscript
  }
}

@MainActor
public final class PushToTalkHotkeyMonitor {
  private var keyDownMonitor: Any?
  private var keyUpMonitor: Any?
  private var isPressed = false
  private let keyCodeSpace: UInt16 = 49

  public init() {}

  public func start(onPressChanged: @escaping (Bool) -> Void) {
    stop()
    keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      let isPushToTalk = event.keyCode == self.keyCodeSpace && event.modifierFlags.contains(.option)
      guard isPushToTalk else { return event }
      if !self.isPressed {
        self.isPressed = true
        onPressChanged(true)
      }
      return nil
    }
    keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
      guard let self else { return event }
      let isPushToTalk = event.keyCode == self.keyCodeSpace && event.modifierFlags.contains(.option)
      guard isPushToTalk else { return event }
      if self.isPressed {
        self.isPressed = false
        onPressChanged(false)
      }
      return nil
    }
  }

  public func stop() {
    if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
    if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    keyDownMonitor = nil
    keyUpMonitor = nil
    isPressed = false
  }
}
