import AppKit

// Entry point. Cursor+ is a menu-bar agent (no Dock icon, no main window). The
// AppController is held by a top-level binding so it lives for the whole run;
// NSApplication.delegate is a weak reference.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
