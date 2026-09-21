import AppKit

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
