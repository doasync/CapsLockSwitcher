import AppKit

// --- Application Entry Point ---

// Create the shared application instance.
let app = NSApplication.shared

// Create the application delegate instance.
let delegate = AppDelegate()

// Assign the delegate to the application.
app.delegate = delegate

// Start the main run loop. This function does not return.
// It loads nibs (though we have none), sets up NSApp,
// and begins processing events.
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

// Note: Code here will not be executed as NSApplicationMain runs indefinitely.
