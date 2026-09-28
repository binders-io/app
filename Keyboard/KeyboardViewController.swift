import SwiftUI
import UIKit

/// The Binders keyboard: a plain typing keyboard with a mic that dictates through the Binders app. The words are typed
/// where you are when you're done talking.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var observer: DarwinObserver?
    private var poll: Timer?
    private var lastShift = Date.distantPast
    private var lastWasSpace = false

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: 272)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        observer = DarwinObserver(KeyboardBridge.stateChanged) { [weak self] in self?.refresh() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        model.showsGlobe = needsInputModeSwitchKey
        model.note = nil
        model.layer = .letters
        textChanged()
        refresh()
        // Darwin notifications can be missed while the keyboard is being set up; a slow look keeps it right.
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poll?.invalidate()
        poll = nil
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        textChanged()
    }

    /// A new field, or the text moved under the keyboard: capitals and the return key follow it.
    private func textChanged() {
        model.returnTitle = Self.returnTitle(textDocumentProxy.returnKeyType)
        autoShift()
    }

    private func refresh() {
        guard hasFullAccess else { return }
        let state = KeyboardBridge.read()
        if model.starting, state.phase == .listening || state.phase == .failed { model.starting = false }
        model.state = state
        if state.phase == .done, KeyboardBridge.lastTyped != state.dictation {
            type(state.text, dictation: state.dictation)
        }
    }

    // MARK: Keys

    func micTapped() {
        guard hasFullAccess else {
            model.note = "To dictate, allow Full Access: Settings → General → Keyboard → Keyboards → Binders."
            return
        }
        model.note = nil
        switch model.state.phase {
        case .listening:
            KeyboardBridge.send(.stop)
        case .cleaning:
            break
        case .ready, .done, .failed:
            model.starting = true
            KeyboardBridge.send(.start)
            // No answer: the app is gone after all, so open it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.model.starting else { return }
                self.model.starting = false
                self.openApp()
            }
        case .off:
            openApp()
        }
    }

    func cancelTapped() {
        KeyboardBridge.send(.cancel)
    }

    func type(_ text: String, dictation: UUID) {
        KeyboardBridge.lastTyped = dictation
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let spacer = before.isEmpty || before.last?.isWhitespace == true ? "" : " "
        let typed = spacer + text
        textDocumentProxy.insertText(typed)
        model.undoable = typed
        lastWasSpace = false
        KeyboardBridge.send(.typed)
        autoShift()
    }

    func undoTapped() {
        guard let typed = model.undoable else { return }
        for _ in typed { textDocumentProxy.deleteBackward() }
        model.undoable = nil
        autoShift()
    }

    func typeKey(_ key: String) {
        model.undoable = nil
        lastWasSpace = false
        let shifted = model.layer == .letters && model.shift != .off
        textDocumentProxy.insertText(shifted ? key.uppercased() : key)
        if model.shift == .once { model.shift = .off }
        // After an apostrophe, back to letters, as the system keyboard does.
        if key == "'", model.layer != .letters { model.layer = .letters }
    }

    /// Two spaces after a word end the sentence.
    func space() {
        model.undoable = nil
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if lastWasSpace, before.hasSuffix(" "), let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastWasSpace = false
        } else {
            textDocumentProxy.insertText(" ")
            lastWasSpace = true
        }
        if model.layer != .letters { model.layer = .letters }
        autoShift()
    }

    func returnTapped() {
        model.undoable = nil
        lastWasSpace = false
        textDocumentProxy.insertText("\n")
        autoShift()
    }

    func deleteBackward() {
        model.undoable = nil
        lastWasSpace = false
        textDocumentProxy.deleteBackward()
        autoShift()
    }

    /// Once for a capital, twice quickly to keep capitals on.
    func shiftTapped() {
        let now = Date()
        if model.shift == .once, now.timeIntervalSince(lastShift) < 0.35 {
            model.shift = .locked
        } else {
            model.shift = model.shift == .off ? .once : .off
        }
        lastShift = now
    }

    /// Capitals where the field wants them: at the start of a sentence, or of every word.
    private func autoShift() {
        guard model.shift != .locked else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let startsSomething: Bool
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: startsSomething = false
        case .allCharacters: startsSomething = true
        case .words: startsSomething = before.isEmpty || before.last?.isWhitespace == true
        default:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            startsSomething = trimmed.isEmpty || before.hasSuffix("\n") || (before.last == " " && [".", "!", "?"].contains(trimmed.last))
        }
        model.shift = startsSomething ? .once : .off
    }

    private static func returnTitle(_ type: UIReturnKeyType?) -> String? {
        switch type {
        case .go: "go"
        case .search, .google, .yahoo: "search"
        case .send: "send"
        case .done: "done"
        case .next: "next"
        case .join: "join"
        case .route: "route"
        case .continue: "continue"
        case .emergencyCall: "call"
        default: nil
        }
    }

    func nextKeyboard() {
        advanceToNextInputMode()
    }

    /// Keyboards can't open apps through the documented API, so this goes through the app in the responder chain, as
    /// other dictation keyboards do; a scene takes the same message with options of its own.
    private func openApp() {
        let selector = sel_registerName("openURL:options:completionHandler:")
        let url = KeyboardBridge.listenURL as NSURL
        var chain: [UIResponder] = []
        var responder: UIResponder? = self
        while let current = responder {
            chain.append(current)
            responder = current.next
        }
        if let app = chain.first(where: { $0 is UIApplication }), app.responds(to: selector), let method = app.method(for: selector) {
            typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
            unsafeBitCast(method, to: Open.self)(app, selector, url, NSDictionary(), nil)
        } else if let scene = chain.first(where: { $0 is UIScene }), scene.responds(to: selector), let method = scene.method(for: selector) {
            typealias Open = @convention(c) (AnyObject, Selector, NSURL, AnyObject?, (@convention(block) (Bool) -> Void)?) -> Void
            unsafeBitCast(method, to: Open.self)(scene, selector, url, UIScene.OpenExternalURLOptions(), nil)
        } else {
            model.note = "Open Binders to start the microphone, then come back here."
        }
    }
}

@MainActor
@Observable
final class KeyboardModel {
    weak var controller: KeyboardViewController?
    var state = KeyboardBridge.State()
    var hasFullAccess = false
    var showsGlobe = true
    /// The mic key was tapped and the app hasn't started yet.
    var starting = false
    /// What was just typed, until something else is.
    var undoable: String?
    /// Something to say that isn't the app's state.
    var note: String?
    var layer = Layer.letters
    var shift = Shift.off
    /// The return key's word, when the field has one ("send", "search"); the symbol otherwise.
    var returnTitle: String?

    enum Layer { case letters, numbers, symbols }
    enum Shift { case off, once, locked }

    /// The keys make way for the dictation while it's on.
    var isDictating: Bool { starting || state.phase == .listening || state.phase == .cleaning }
}
