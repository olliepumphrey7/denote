import AppKit
import DenoteCore

if let bundleIdentifier = Bundle.main.bundleIdentifier,
   let existingInstance = NSRunningApplication
    .runningApplications(withBundleIdentifier: bundleIdentifier)
    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existingInstance.activate()
    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
