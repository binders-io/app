import Foundation

/// How the Binders keyboard and the Binders app talk. A keyboard can't use the microphone, so the app listens for it: the
/// keyboard sends commands, the app writes what it heard to a file in their shared App Group, and a Darwin notification
/// says either side has something new. The keyboard needs Full Access to reach the shared folder.
enum KeyboardBridge {
    static let group = "group.io.binders.app"
    /// Opens the app and has it start listening for the keyboard.
    static let listenURL = URL(string: "binders://keyboard")!
    /// How long the app keeps the microphone ready after a dictation, so the next one starts without a trip to the app.
    static let warmFor: TimeInterval = 5 * 60

    enum Phase: String, Codable {
        /// The app isn't listening for the keyboard: the mic key opens it.
        case off
        /// The microphone is ready: the mic key starts at once.
        case ready
        case listening
        case cleaning
        /// `text` is the result, waiting to be typed.
        case done
        /// `text` says what went wrong.
        case failed
    }

    struct State: Codable, Equatable {
        var phase: Phase = .off
        /// The words so far while listening; the cleaned-up result when done.
        var text = ""
        /// How loud it is, 0…1.
        var level: Double = 0
        /// New for every dictation, so each result is typed once.
        var dictation = UUID()
        /// The app writes at least every couple of seconds while it's on; older than that, it's gone.
        var written = Date()

        /// What the keyboard should believe: an app that stopped writing is off, whatever it last said.
        var current: State {
            guard phase != .off, Date().timeIntervalSince(written) > 6 else { return self }
            var gone = self
            gone.phase = .off
            return gone
        }
    }

    enum Command: String, CaseIterable {
        case start, stop, cancel
        /// The keyboard typed the result.
        case typed
    }

    // MARK: State, written by the app

    private static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    private static var stateFile: URL? { folder?.appendingPathComponent("keyboard.json") }
    /// The last result the keyboard typed, written by the keyboard.
    private static var typedFile: URL? { folder?.appendingPathComponent("keyboard-typed.txt") }

    /// Whether this process can reach the shared folder: a keyboard without Full Access can't.
    static var isReachable: Bool { folder != nil }

    static func read() -> State {
        guard let url = stateFile, let data = try? Data(contentsOf: url), let state = try? decoder.decode(State.self, from: data)
        else { return State() }
        return state.current
    }

    static func write(_ state: State) {
        var state = state
        state.written = Date()
        guard let url = stateFile, let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        post(stateChanged)
    }

    static var lastTyped: UUID? {
        get { typedFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap { UUID(uuidString: $0) } }
        set {
            guard let url = typedFile else { return }
            try? (newValue?.uuidString ?? "").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Notifications

    static let stateChanged = "io.binders.keyboard.state"
    static func name(_ command: Command) -> String { "io.binders.keyboard.\(command.rawValue)" }

    static func send(_ command: Command) { post(name(command)) }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Hears a Darwin notification, from another process, for as long as it's kept.
final class DarwinObserver {
    private let name: String
    private let handler: @MainActor () -> Void

    init(_ name: String, _ handler: @escaping @MainActor () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
                                            guard let observer else { return }
                                            let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                                            DispatchQueue.main.async { MainActor.assumeIsolated { me.handler() } }
                                        },
                                        name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(name as CFString), nil)
    }
}
