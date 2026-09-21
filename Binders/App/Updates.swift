import AppKit
import Sparkle

/// In-place updates through Sparkle. The feed is a static file on binders.io and every update is verified against
/// the EdDSA public key in Info.plist (and Apple's code signature) before it is installed. Automatic checks happen
/// only once the user has agreed: Sparkle asks on the second launch, and Settings has the switch.
@MainActor
final class UpdateService: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateService()

    private var controller: SPUStandardUpdaterController?
    /// Set by the app so a found update can be announced without stealing focus.
    var announce: ((String) -> Void)?
    /// The version a scheduled check found and the user hasn't looked at yet.
    private(set) var pendingVersion: String?

    var updater: SPUUpdater? { controller?.updater }

    func start() {
        guard controller == nil, !AppPaths.isDemo else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        return "Binders \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: Gentle reminders: a menu bar app should not throw a window at you from a scheduled check.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            guard !handleShowingUpdate else { self.pendingVersion = nil; return }
            self.pendingVersion = version
            self.announce?("Binders \(version) is available. Choose Update in the menu bar menu.")
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.pendingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.pendingVersion = nil }
    }
}

/// Headless probe for `--selftest-update-check <feed url>`: asks Sparkle whether the feed offers a newer, validly
/// described version than the running build, without showing any window or installing anything.
final class UpdateProbe: NSObject, SPUUpdaterDelegate {
    private let feed: String
    private var continuation: CheckedContinuation<String, Never>?

    init(feed: String) { self.feed = feed }

    func feedURLString(for updater: SPUUpdater) -> String? { feed }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        finish("UPDATE_FOUND \(item.displayVersionString) (\(item.versionString)) url=\(item.fileURL?.absoluteString ?? "?")")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        finish("NO_UPDATE \((error as NSError).localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        finish("ABORTED \((error as NSError).localizedDescription)")
    }

    private func finish(_ line: String) {
        continuation?.resume(returning: line)
        continuation = nil
    }

    @MainActor
    func run() async -> String {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do { try updater.start() } catch { return "START_FAILED \(error.localizedDescription)" }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            updater.checkForUpdateInformation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish("TIMEOUT") }
        }
    }
}
