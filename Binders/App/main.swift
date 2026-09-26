import AppKit

if CommandLine.arguments.contains("--mcp") {
    // A host is on the other end of stdin: no UI, no housekeeping writes, just the protocol. And no NSApplication:
    // creating one registers this process with Launch Services as Binders, so opening Binders from the Dock or Finder
    // would bring this invisible server forward instead of starting the app. A plain run loop serves the requests.
    MainActor.assumeIsolated { MCPServer.start() }
    RunLoop.main.add(Timer(timeInterval: 1_000_000_000, repeats: true) { _ in }, forMode: .default)
    while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
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
