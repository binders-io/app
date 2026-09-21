import AppKit
import Foundation
import Observation
import Security

/// Installs Ollama for people who don't have it: downloads the official build from ollama.com, proves it was signed
/// by Ollama's own developer team and notarized by Apple, puts it in Applications, opens it and waits for it to answer.
/// A file an app downloads for itself never meets Gatekeeper, so the checks here are what stands between a tampered
/// download and the user's Mac. Nothing happens without an explicit click.
@MainActor
@Observable
final class OllamaInstaller {
    static let shared = OllamaInstaller()

    enum Phase: Equatable {
        case idle, downloading(Double), verifying, installing, starting, done, failed(String)
    }

    /// The official macOS build, and the Apple developer team that signs it (Infra Technologies, Inc).
    static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    static let signingTeam = "3MU9H2V9Y9"
    static let bundleIdentifiers = ["com.electron.ollama", "com.ollama.ollama"]

    private(set) var phase: Phase = .idle

    var isWorking: Bool {
        switch phase {
        case .downloading, .verifying, .installing, .starting: return true
        default: return false
        }
    }

    var progress: Double? {
        if case .downloading(let fraction) = phase { return fraction }
        return isWorking ? nil : nil
    }

    var statusLine: String? {
        switch phase {
        case .idle, .done: return nil
        case .downloading(let fraction): return "Downloading Ollama from ollama.com… \(Int(fraction * 100))%"
        case .verifying: return "Checking that the download was signed by Ollama and notarized by Apple…"
        case .installing: return "Putting Ollama in your Applications folder…"
        case .starting: return "Opening Ollama and waiting for it to answer…"
        case .failed(let message): return "Couldn't install Ollama: \(message)"
        }
    }

    /// Where an existing copy lives, if there is one.
    static var installedURL: URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        let candidates = [URL(fileURLWithPath: "/Applications/Ollama.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ollama.app")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Asks first. Returns true when Ollama is installed and answering.
    @discardableResult
    func installWithConsent(serverURL: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install Ollama?"
        alert.informativeText = "Ollama is free, open-source software from Ollama that runs language models on your Mac. It is separate from Binders and keeps itself up to date.\n\n"
            + "Binders will download it from ollama.com (about 200 MB), check that it was signed by its makers and notarized by Apple, put it in your Applications folder and open it."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Download It Myself")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return await install(serverURL: serverURL)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
            return false
        default: return false
        }
    }

    /// Opens a copy that is installed but not running, and waits for it.
    @discardableResult
    func open(serverURL: String) async -> Bool {
        guard let app = Self.installedURL else { return false }
        phase = .starting
        let ok = await launch(app, serverURL: serverURL)
        phase = ok ? .done : .failed("Ollama opened but isn't answering yet. Give it a moment, then check again.")
        return ok
    }

    /// The whole sequence. `directory` and `launchAfter` exist so a self-test can run everything into a throwaway folder.
    @discardableResult
    func install(serverURL: String, into directory: URL? = nil, launchAfter: Bool = true) async -> Bool {
        guard !isWorking else { return false }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("binders-ollama-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: work) }
        do {
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
            phase = .downloading(0)
            let archive = work.appendingPathComponent("Ollama-darwin.zip")
            try await Downloader.fetch(Self.downloadURL, to: archive) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                }
            }

            phase = .verifying
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            guard let app = try manager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                throw InstallError("the download didn't contain an app")
            }
            try Self.verifySignature(of: app)
            try await Self.verifyNotarization(of: app)

            phase = .installing
            let destination = try Self.place(app, in: directory)

            if launchAfter {
                phase = .starting
                guard await launch(destination, serverURL: serverURL) else {
                    phase = .failed("Ollama is installed but isn't answering yet. Open it from Applications, then check again.")
                    return false
                }
            }
            phase = .done
            Log.app.notice("Ollama installed at \(destination.path, privacy: .public)")
            return true
        } catch {
            phase = .failed((error as? InstallError)?.message ?? error.localizedDescription)
            Log.app.error("Ollama install failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Steps

    struct InstallError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Valid signature, every architecture and all nested code, from Ollama's Developer ID team and nobody else.
    nonisolated static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw InstallError("the download isn't a signed app")
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(signingTeam)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw InstallError("couldn't build the signature requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var failure: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &failure) == errSecSuccess else {
            let reason = failure.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown reason"
            throw InstallError("the download is not signed by Ollama (\(reason))")
        }
    }

    /// Gatekeeper's own verdict, which includes Apple's notarization.
    nonisolated static func verifyNotarization(of app: URL) async throws {
        let output = try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-v", app.path], allowFailure: true)
        guard output.status == 0, output.text.contains("Notarized") else {
            throw InstallError("Apple's notarization check did not pass")
        }
    }

    /// /Applications when it is writable, the user's own Applications folder otherwise. Never overwrites an existing copy.
    nonisolated static func place(_ app: URL, in directory: URL?) throws -> URL {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let folders = directory.map { [$0] } ?? [URL(fileURLWithPath: "/Applications", isDirectory: true), home]
        var lastError: Error?
        for folder in folders {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent("Ollama.app")
                guard !manager.fileExists(atPath: destination.path) else { return destination }
                try manager.copyItem(at: app, to: destination)
                return destination
            } catch {
                lastError = error
            }
        }
        throw InstallError("couldn't write to Applications (\(lastError?.localizedDescription ?? "no permission"))")
    }

    private func launch(_ app: URL, serverURL: String) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        return await Self.waitForServer(serverURL, seconds: 60)
    }

    nonisolated static func waitForServer(_ serverURL: String, seconds: Int) async -> Bool {
        guard let base = URL(string: serverURL) else { return false }
        var request = URLRequest(url: base.appendingPathComponent("api/version"), timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for _ in 0..<max(1, seconds) {
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String], allowFailure: Bool = false) async throws -> (status: Int32, text: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus != 0, !allowFailure {
                    continuation.resume(throwing: InstallError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.prefix(200))"))
                } else {
                    continuation.resume(returning: (finished.terminationStatus, text))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// A file download with progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func fetch(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Downloader(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw OllamaInstaller.InstallError("ollama.com answered with status \(status)") }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
