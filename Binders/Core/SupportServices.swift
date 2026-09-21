import AppKit
import AVFoundation
import Observation
import BindersKit

enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    static func openSystemAudioSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// True when the 🌐/fn key is set to "Do Nothing", so holding it won't open the emoji picker.
    static var globeKeyDoesNothing: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) == 0
    }

    static var wisprFlowRunning: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.electron.wispr-flow" }
    }
}

@MainActor
enum Sounds {
    private static func play(_ name: String, volume: Float = 0.35) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    static func start() { play("Tink", volume: 0.3) }
    static func stop() { play("Pop", volume: 0.3) }
    static func cancel() { play("Funk", volume: 0.25) }
    static func error() { play("Basso", volume: 0.3) }
}

enum SpellCheck {
    @MainActor
    static func isKnownWord(_ word: String) -> Bool {
        guard word.count > 1 else { return true }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
}

/// Re-runs `apply` whenever an observable value read inside `value` changes.
@MainActor
func observeChanges<T: Equatable>(_ value: @escaping @MainActor () -> T, onChange: @escaping @MainActor (T) -> Void) {
    let current = withObservationTracking {
        value()
    } onChange: {
        Task { @MainActor in
            onChange(value())
            observeChanges(value, onChange: onChange)
        }
    }
    _ = current
}

/// Loads and owns the active speech-to-text engine.
@MainActor
@Observable
final class SpeechService {
    enum LoadState: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var modelID: SpeechModelID?
    @ObservationIgnored private var engine: (any SpeechEngine)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Identifies the latest load so a superseded one can't mark a different engine ready.
    @ObservationIgnored private var loadToken = UUID()

    var readyEngine: (any SpeechEngine)? { state == .ready ? engine : nil }

    func isDownloaded(_ model: SpeechModelID) -> Bool {
        makeEngine(model).isDownloaded()
    }

    /// Switches to `model`; downloads it if needed when `download` is true.
    func activate(_ model: SpeechModelID, download: Bool) {
        if modelID == model, state == .ready || loadTask != nil { return }
        let engine = modelID == model && self.engine != nil ? self.engine! : makeEngine(model)
        self.engine = engine
        modelID = model
        loadTask?.cancel()
        loadTask = nil
        let token = UUID()
        loadToken = token
        guard download || engine.isDownloaded() else {
            state = .idle
            return
        }
        state = engine.isDownloaded() ? .loading : .downloading(0)
        loadTask = Task { [weak self] in
            do {
                try await engine.load(progress: { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadToken == token else { return }
                        if case .downloading = self.state { self.state = fraction >= 0.999 ? .loading : .downloading(fraction) }
                    }
                })
                guard let self, self.loadToken == token else { return }
                self.state = .ready
            } catch {
                guard let self, self.loadToken == token else { return }
                Log.speech.error("Model load failed: \(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
            if let self, self.loadToken == token { self.loadTask = nil }
        }
    }

    func waitUntilReady() async throws -> any SpeechEngine {
        while let task = loadTask {
            let token = loadToken
            await task.value
            if loadToken == token { break }
        }
        guard state == .ready, let engine else {
            if case .failed(let message) = state { throw NSError(domain: "Binders", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            throw SpeechError.notLoaded
        }
        return engine
    }

    private func makeEngine(_ model: SpeechModelID) -> any SpeechEngine {
        model.isParakeet ? ParakeetEngine(modelID: model) : WhisperEngine()
    }
}

/// Shown once, before the first meeting is recorded.
@MainActor
enum RecordingNotice {
    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Let everyone know you're recording"
        alert.informativeText = "Binders records your microphone and what the other people on the call say, and keeps it on this Mac. "
            + "Many places require everyone's consent before a conversation is recorded. Tell the people you're meeting with, and don't record if someone objects."
        alert.addButton(withTitle: "I'll Let Them Know")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
