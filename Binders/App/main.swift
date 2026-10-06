import AppKit

if CommandLine.arguments.contains("--mcp") {
    // A host is on the other end of stdin: no UI, no housekeeping writes, just the protocol. And no NSApplication:
    // creating one registers this process with Launch Services as Binders, so opening Binders from the Dock or Finder
    // would bring this invisible server forward instead of starting the app. A plain run loop serves the requests.
    MainActor.assumeIsolated { MCPServer.start() }
    RunLoop.main.add(Timer(timeInterval: 1_000_000_000, repeats: true) { _ in }, forMode: .default)
    while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
}

// An AI tool's hook handing over a prompt you sent it: no app, no window, done in a moment.
if CommandLine.arguments.contains("--capture-prompt") { PromptHook.run(CommandLine.arguments) }

// A run meant for a throwaway folder whose folder was refused (it holds files and isn't one Binders made) stops here,
// before anything reads, tidies or tests the real data in its place.
if ProcessInfo.processInfo.environment["BINDERS_DATA_DIR"] != nil, !AppPaths.isDemo {
    FileHandle.standardError.write(Data("BINDERS_DATA_DIR has to be an empty folder, or one Binders made for a test run. Nothing was done.\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    if let index = CommandLine.arguments.firstIndex(of: "--appearance"), CommandLine.arguments.indices.contains(index + 1) {
        AppAppearance.apply(CommandLine.arguments[index + 1])   // headless renders in a chosen appearance
    } else {
        AppAppearance.apply(AppSettings.shared.appearance)
    }
    Store.shared.ensureBinders()
    Store.shared.pruneWriting(olderThanDays: AppSettings.shared.captureRetentionDays)
    Store.shared.cleanupWriting()
    NoteHistory.forgetDeletedNotes()
    Attachments.trashUnused()
    if let index = CommandLine.arguments.firstIndex(where: { $0.hasPrefix("--selftest") }) {
        application.setActivationPolicy(.accessory)
        SelfTest.start(arguments: Array(CommandLine.arguments[index...]))
        application.run()
    } else {
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
