import AppKit

// Entry point. As an "accessory" app we have no Dock icon and no app menu,
// behaving like a background agent that owns a strip at the bottom of the screen.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
