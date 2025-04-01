import Cocoa
import InputMethodKit
import Carbon.HIToolbox
import Accessibility
import ServiceManagement
import OSLog // Make sure this is imported for OSAllocatedUnfairLock too

// MARK: - Logger Categories

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.example.CapsLockSwitcherRemap"
    static let app = Logger(subsystem: subsystem, category: "Application")
    static let state = Logger(subsystem: subsystem, category: "StateManagement")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    static let eventTap = Logger(subsystem: subsystem, category: "EventTap")
    static let hid = Logger(subsystem: subsystem, category: "HIDUtil")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    // Add Timer category for clarity
    static let timer = Logger(subsystem: subsystem, category: "PermissionTimer")
}

// MARK: - Global Event Tap Callback (SYNCHRONOUS - Listens for LANG)

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    guard let refcon = refcon else {
        Logger.eventTap.error("FATAL: refcon is nil in eventTapCallback") // Use Logger
        // Cannot access AppDelegate instance here safely, so just pass through
        return Unmanaged.passRetained(event)
    }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    
    //Logger.eventTap.error("Code:  \(keyCode) ")
    
    guard keyCode == delegate.triggerKeyCode else {
        return Unmanaged.passRetained(event)
    }

    // *** THIS IS THE KEY SAFETY CHECK (Option 1) ***
    // Check the permission flag *before* potentially calling TIS functions
    guard delegate.checkKnownPermissionsFlag() else {
        // Log already happens inside checkKnownPermissionsFlag if false
        return Unmanaged.passRetained(event) // Pass LANG through if permissions are known to be missing
    }
    // **********************************************

    // Proceed with the switch logic only if the flag check passed
    let shouldConsume = delegate.performSwitchIfActiveSync()

    if shouldConsume {
        return nil // Consume the LANG event
    } else {
        return Unmanaged.passRetained(event) // Pass through (e.g., if state wasn't .active)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Constants & Core Properties

    private enum PrefKeys {
        static let selectedSourceID1 = "selectedSourceID1"
        static let selectedSourceID2 = "selectedSourceID2"
        static let hasShownWelcome = "hasShownWelcome"
    }

    private let hidCapsLockUsage = 0x700000039
    private let hidLangKeyUsage = 0x700000090 // Keyboard LANG1
    internal let triggerKeyCode = CGKeyCode(104)

    fileprivate enum AppOperationalState: String, CustomStringConvertible {
        case permissionsRequired = "Permissions Required"
        case configuring = "Configuring"
        case active = "Active"

        var description: String { self.rawValue }
    }

    private var isShowingPermissionAlert = false

    private var statusItem: NSStatusItem?
    private var appMenu: NSMenu?
    private var statusMenuItem: NSMenuItem?

    fileprivate struct AppState {
        var selectedSourceID1: String? = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID1)
        var selectedSourceID2: String? = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID2)
        var targetSource1Ref: TISInputSource? = nil
        var targetSource2Ref: TISInputSource? = nil
        var availableSelectionCount: Int = 0
        var allSelectableSources: [TISInputSource] = []
        var menuItemToSourceMap: [NSMenuItem: TISInputSource] = [:]
        var eventTap: CFMachPort? = nil
        var runLoopSource: CFRunLoopSource? = nil
        var currentOperationalState: AppOperationalState = .permissionsRequired // Start assuming permissions are needed
        var isHidRemappingApplied: Bool = false
    }
    fileprivate var state = AppState()

    // --- NEW: Properties for Periodic Permission Check (Option 1) ---
    private let permissionCheckLock = OSAllocatedUnfairLock()
    private var hasKnownAccessibilityPermissions: Bool = false // Protected by lock
    private var permissionCheckTimer: Timer?
    private let permissionCheckInterval: TimeInterval = 3.0 // Check every 3 seconds
    // ----------------------------------------------------------------

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Logger.app.info("CapsLockSwitcher (HID Remap): Did Finish Launching")
        manageHidRemapping(enable: false, context: "Launch Initial Reset") // Ensure reset on launch

        // Perform initial state check and UI setup
        determineStateAndSetupUI(context: "Launch")

        // --- NEW: Start Periodic Permission Check ---
        // Perform an immediate check to initialize the flag correctly
        checkPermissionsAndUpdateFlag()
        // Schedule the timer
        setupPermissionCheckTimer()
        // --------------------------------------------
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        Logger.app.info("CapsLockSwitcher (HID Remap): Will Terminate")

        // --- NEW: Stop Periodic Permission Check ---
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        Logger.timer.info("Permission check timer invalidated.")
        // -------------------------------------------

        // Perform cleanup
        manageHidRemapping(enable: false, context: "Terminate")
        destroyEventTap()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - Periodic Permission Check Logic (Option 1)

    private func setupPermissionCheckTimer() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard permissionCheckTimer == nil else { return } // Don't create multiple timers
        Logger.timer.info("Setting up periodic permission check timer (Interval: \(self.permissionCheckInterval)s).")
        permissionCheckTimer = Timer.scheduledTimer(
            timeInterval: permissionCheckInterval,
            target: self,
            selector: #selector(checkPermissionsPeriodically),
            userInfo: nil,
            repeats: true
        )
        // Ensure it runs even when modal panels are up (like save dialogs)
        RunLoop.current.add(permissionCheckTimer!, forMode: .common)
    }

    /// Checks permissions and updates the thread-safe flag.
    /// Should be called on the main thread.
    private func checkPermissionsAndUpdateFlag() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let currentPermissions = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
        permissionCheckLock.lock()
        hasKnownAccessibilityPermissions = currentPermissions
        permissionCheckLock.unlock()
        Logger.permissions.debug("Updated hasKnownAccessibilityPermissions flag to: \(currentPermissions)")
    }

    /// Called by the timer to check for permission changes.
    @objc private func checkPermissionsPeriodically() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Logger.timer.debug("Timer fired: Checking permissions...")

        let currentPermissions = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
        var previousPermissions: Bool = false

        // Safely read previous and update current
        permissionCheckLock.lock()
        previousPermissions = hasKnownAccessibilityPermissions
        if previousPermissions != currentPermissions {
            hasKnownAccessibilityPermissions = currentPermissions // Update the flag
            Logger.permissions.info("Permission status changed: \(previousPermissions) -> \(currentPermissions)")
        }
        permissionCheckLock.unlock()

        // If status changed, trigger a full state update
        if previousPermissions != currentPermissions {
            Logger.state.info("Permission change detected by timer, triggering state update.")
            determineStateAndSetupUI(context: "Permission Change Detected")
        } else {
             // Logger.timer.debug("No permission change detected.")
        }
    }

    /// Thread-safe check of the known permission status flag.
    /// Called from the synchronous event tap callback. Returns true if permissions are known to be granted.
    fileprivate func checkKnownPermissionsFlag() -> Bool {
        permissionCheckLock.lock()
        let permissionsKnown = hasKnownAccessibilityPermissions
        permissionCheckLock.unlock()

        if !permissionsKnown {
            Logger.permissions.warning("SYNC Event Check: Blocking action because hasKnownAccessibilityPermissions is false.")
        }
        return permissionsKnown
    }


    // MARK: - Core State Determination & UI Setup (Manages HID Remapping)

    private func determineStateAndSetupUI(context: String) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.state.debug("Determining state (Context: \(context))...")

        // 1. Check Permissions
        let hasPermissions = checkAccessibilityPermissions(promptUserIfNeeded: false)

        // --- NEW: Update the shared flag whenever we do a check ---
        permissionCheckLock.lock()
        let flagChanged = (hasKnownAccessibilityPermissions != hasPermissions)
        hasKnownAccessibilityPermissions = hasPermissions
        permissionCheckLock.unlock()
        if flagChanged {
             Logger.permissions.info("Updated hasKnownAccessibilityPermissions flag to \(hasPermissions) during state determination (Context: \(context))")
        }
        // -------------------------------------------------------


        // 2. Fetch Sources & Check Selections (only if permissions OK)
        var determinedSelectionCount = 0
        if hasPermissions {
            fetchAllSelectableSources()
            updateActiveTargetRefsAndAvailabilityCount()
            determinedSelectionCount = state.availableSelectionCount
        } else {
            // Ensure these are cleared if permissions are lost
            state.availableSelectionCount = 0
            state.targetSource1Ref = nil
            state.targetSource2Ref = nil
            state.allSelectableSources = []
            state.menuItemToSourceMap = [:]
        }

        // 3. Determine Operational State
        let determinedState = determineCurrentOperationalState(
            hasPermissions: hasPermissions,
            availableSelectionCount: determinedSelectionCount
        )
        let previousState = state.currentOperationalState
        let stateChanged = (previousState != determinedState)
        Logger.state.info("State Check: Prev=\(previousState.description), New=\(determinedState.description), Changed=\(stateChanged)")


        // --- 4. Manage HID Remapping based on State Transition ---
        if stateChanged {
            if determinedState == .active {
                // Only enable if not already applied (safety check)
                if !state.isHidRemappingApplied {
                    manageHidRemapping(enable: true, context: "Entering Active State")
                } else {
                     Logger.hid.warning("State changed to Active, but HID remapping was already applied. Skipping enable.")
                }
            } else { // Moving to Configuring or PermissionsRequired
                // Only disable if currently applied (safety check)
                if state.isHidRemappingApplied {
                    manageHidRemapping(enable: false, context: "Exiting Active State (To \(determinedState.description))")
                } else {
                    Logger.hid.warning("State changed away from Active (\(determinedState.description)), but HID remapping was not applied. Skipping disable.")
                }
            }
        } else {
            // Handle cases where state *didn't* change but remapping might be inconsistent
             if determinedState == .active && !state.isHidRemappingApplied {
                 Logger.hid.warning("State is Active, but remapping wasn't applied. Attempting to apply now (Context: \(context)).")
                 manageHidRemapping(enable: true, context: "Re-applying Active State (\(context))")
             } else if determinedState != .active && state.isHidRemappingApplied {
                 Logger.hid.warning("State is NOT Active (\(determinedState.description)), but remapping is still applied. Attempting to remove now (Context: \(context)).")
                 manageHidRemapping(enable: false, context: "Forced Reset Non-Active (\(context))")
             }
        }


        // --- 5. Update Internal State variable ---
        state.currentOperationalState = determinedState

        // --- 6. Setup Status Bar (Icon & Base Menu Structure) ---
        setupStatusBar() // Updates icon based on new state

        // --- 7. Setup/Destroy Event Tap ---
        // Setup if permissions OK, state allows switching, and tap doesn't exist
        if hasPermissions && (determinedState == .active || determinedState == .configuring) && state.eventTap == nil {
             Logger.eventTap.info("Conditions met to set up event tap (Permissions OK, State=\(determinedState.description), Tap is nil)")
             setupEventTap()
        }
        // Destroy if permissions lost OR state doesn't require it anymore, and tap exists
        else if (!hasPermissions || determinedState == .permissionsRequired) && state.eventTap != nil {
             Logger.eventTap.info("Conditions met to destroy event tap (Permissions: \(hasPermissions), State=\(determinedState.description), Tap exists)")
             destroyEventTap()
        }

        // --- 8. Update Dynamic Menu Content ---
        // This needs to happen *after* setupStatusBar which might recreate the menu
        if determinedState == .configuring || determinedState == .active {
             updateMenuState() // Populates layout list, updates status text
        }


        // --- 9. Trigger Alerts ASYNCHRONOUSLY ---
        // Only show permission alert if needed AND state actually requires it AND not already showing
        if determinedState == .permissionsRequired && !isShowingPermissionAlert && (context == "Launch" || stateChanged) {
            isShowingPermissionAlert = true // Prevent spamming alerts
            Logger.permissions.info("Queueing Permission Alert (Context: \(context), State Changed: \(stateChanged))")
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.showAccessibilityInstructionsAlert(triggeredByUserAction: false)
                // Reset flag only *after* alert is dismissed (or potentially immediately if runModal blocks)
                // Doing it here allows re-triggering if needed after dismissal
                strongSelf.isShowingPermissionAlert = false
            }
        } else if determinedState == .configuring && context == "Launch" {
             // Show welcome only on first launch into configuring state
             DispatchQueue.main.async { [weak self] in
                 self?.showWelcomeMessageIfNeeded()
             }
        }
        Logger.state.debug("State determination and UI setup complete (Context: \(context)).")
    }

    // Simplified state determination
    private func determineCurrentOperationalState(hasPermissions: Bool, availableSelectionCount: Int) -> AppOperationalState {
        if !hasPermissions { return .permissionsRequired }
        // Only Active if permissions are granted AND exactly 2 layouts are selected AND available
        if availableSelectionCount == 2 { return .active }
        // Otherwise, if permissions are granted but setup isn't complete, it's Configuring
        return .configuring
    }

    // MARK: - Synchronous Event Handling (Called from C callback for LANG)

    /// Performs the input source switch if the app is in the Active state.
    /// Called SYNCHRONOUSLY from the event tap callback. Must be non-blocking.
    /// Assumes permission check (`checkKnownPermissionsFlag`) already passed.
    fileprivate func performSwitchIfActiveSync() -> Bool {
        // 1. Check Operational State (Primary check after permission flag)
        guard state.currentOperationalState == .active else {
            // This log indicates LANG was pressed but the app wasn't fully ready (e.g., configuring)
            Logger.eventTap.debug("SYNC Switch: Pass through. State is not Active (\(self.state.currentOperationalState.description)).")
            return false // State not active, pass event through
        }

        // 2. Check Target References (Safety check, should always be valid in .active state)
        guard let source1 = state.targetSource1Ref, let source2 = state.targetSource2Ref else {
             Logger.eventTap.error("SYNC Switch FAIL: Missing target refs in Active state. This shouldn't happen.")
             // Consider this a failure state, consume the event to prevent unexpected LANG behavior? Or pass through?
             // Let's consume it to prevent potential issues.
             return true
        }

        // 3. Get Current Input Source
        guard let currentSourceUnmanaged = TISCopyCurrentKeyboardInputSource() else {
             Logger.eventTap.error("SYNC Switch FAIL: TISCopyCurrentKeyboardInputSource returned nil.")
             return true // Consume event on failure
        }
        let currentSource = currentSourceUnmanaged.takeRetainedValue() // Balance the retain

        // 4. Get Current Source ID (for comparison)
         guard let currentSourceID = getInputSourceID(currentSource) else {
             Logger.eventTap.error("SYNC Switch FAIL: Could not get current source ID.")
             return true // Consume event on failure
         }

        // 5. Determine Target Source
        // Ensure we handle the case where currentSourceID might not match *either* selected ID
        // (e.g., if user manually switched to a 3rd layout via system menu)
        let targetSource: TISInputSource
        let targetIdLog: String
        if currentSourceID == state.selectedSourceID1 {
            targetSource = source2
            targetIdLog = state.selectedSourceID2 ?? "Target2 (ID unknown)"
        } else {
            // Default to source1 if current is not source1 (covers source2 and any other layout)
            targetSource = source1
            targetIdLog = state.selectedSourceID1 ?? "Target1 (ID unknown)"
        }

        Logger.eventTap.debug("SYNC Switching: Current='\(currentSourceID)', Target='\(targetIdLog)'")

        // 6. Perform the Switch
        let status = TISSelectInputSource(targetSource)

        // 7. Log Result
        if status != noErr {
             // Log the specific Carbon error code
             Logger.eventTap.error("SYNC Switch FAILED: TISSelectInputSource returned error \(status).")
             // Still consume the event, as an attempt was made based on app state
             return true
        } else {
             Logger.eventTap.debug("SYNC Switch: Success.")
             // Successfully switched, consume the LANG event
             return true
        }
    }


    // MARK: - HID Remapping Management (Main Thread Only)

    private func manageHidRemapping(enable: Bool, context: String) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Avoid redundant calls
        guard state.isHidRemappingApplied != enable else {
            Logger.hid.debug("Skipping hidutil (\(context)): Remapping state already \(enable ? "Enabled" : "Disabled")")
            return
        }

        Logger.hid.info("Attempting hidutil (\(context)): \(enable ? "ENABLE CapsLock->LANG" : "REVERT CapsLock->CapsLock") remapping...")

        let jsonPayload: String
        if enable {
            // Map CapsLock to LANG
            let mapping = "[{\"HIDKeyboardModifierMappingSrc\":\(hidCapsLockUsage),\"HIDKeyboardModifierMappingDst\":\(hidLangKeyUsage)}]"
            jsonPayload = "{\"UserKeyMapping\":\(mapping)}"
            Logger.hid.debug("hidutil payload (ENABLE): \(jsonPayload)")
        } else {
            // Explicitly map CapsLock back to CapsLock to restore default behavior
            // Using an empty array "[]" might also work but explicit revert is safer.
            let revertMapping = "[{\"HIDKeyboardModifierMappingSrc\":\(hidCapsLockUsage),\"HIDKeyboardModifierMappingDst\":\(hidCapsLockUsage)}]"
            jsonPayload = "{\"UserKeyMapping\":\(revertMapping)}"
            Logger.hid.debug("hidutil payload (REVERT): \(jsonPayload)")
        }

        // Run hidutil asynchronously off the main thread
        Task(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            process.arguments = ["property", "--set", jsonPayload]
            let outputPipe = Pipe()
            let errorPipe = Pipe() // Separate pipes for clarity
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            var commandOutput = "" // Collect output for logging

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let outStr = String(data: outputData, encoding: .utf8), !outStr.isEmpty { commandOutput += "Output:\n\(outStr)\n" }
                if let errStr = String(data: errorData, encoding: .utf8), !errStr.isEmpty { commandOutput += "Error Output:\n\(errStr)" }
                commandOutput = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)


                if process.terminationStatus == 0 {
                    Logger.hid.info("Hidutil: OK (\(context)) - Remapping \(enable ? "ENABLED (->LANG)" : "REVERTED (->CapsLock)").")
                    // Update internal tracking state *only on success*
                    await MainActor.run { [weak self] in
                        self?.state.isHidRemappingApplied = enable
                    }
                } else {
                    Logger.hid.error("Hidutil: FAILED (status \(process.terminationStatus)) (\(context)) - Could not \(enable ? "enable" : "revert") remapping.")
                    if !commandOutput.isEmpty { Logger.hid.error("Hidutil details: \(commandOutput)") }
                    // Don't change isHidRemappingApplied on failure, as the system state is now uncertain.
                    // Consider showing an alert?
                }
            } catch {
                Logger.hid.critical("Hidutil process EXCEPTION (\(context)): \(error.localizedDescription)")
                 // Don't change isHidRemappingApplied on exception.
                 // Consider showing an alert?
            }
        } // End Task
    }


    // MARK: - System Settings & Permissions Checks (Main Thread Only)

    /// Checks Accessibility Permissions. Main thread only.
    /// - Parameter promptUserIfNeeded: If true, system may prompt user if not trusted.
    /// - Returns: True if process is trusted, false otherwise.
    private func checkAccessibilityPermissions(promptUserIfNeeded: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let optionsKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionsKey: promptUserIfNeeded] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Logger.permissions.debug("AXIsProcessTrustedWithOptions (prompt=\(promptUserIfNeeded)) -> \(trusted)")
        return trusted
    }


    // MARK: - Alert Logic (Called Asynchronously from Main Thread)

    private func showAccessibilityInstructionsAlert(triggeredByUserAction: Bool) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Prevent multiple alerts stacking up
        guard NSApplication.shared.modalWindow == nil else {
            Logger.permissions.warning("Accessibility alert skipped: Another modal window (likely an alert) is already visible.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = "\(Bundle.main.appName) needs Accessibility access to monitor Caps Lock key.\n\nPlease go to System Settings > Privacy & Security > Accessibility, find and enable \(Bundle.main.appName), or add it manually using the '+' button."
        if triggeredByUserAction {
            alert.informativeText += "\n\nIf it's enabled but not working, try removing \(Bundle.main.appName) using the '-' button, then add it back again."
            alert.informativeText += "\n\nAfter granting/fixing permissions, click the menu bar icon again."
        } else {
             alert.informativeText += "\n\nAfter granting permissions, click the menu bar icon to continue setup, or wait a few seconds for the app to re-check." // Updated text
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")
        
        Logger.permissions.info("Displaying Accessibility Instructions Alert.")
        let response = alert.runModal() // This blocks until dismissed

        if response == .alertFirstButtonReturn {
            // Try opening the specific pane
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
                Logger.permissions.info("Accessibility Alert: Opened settings pane.")
            } else {
                Logger.permissions.error("Failed to create URL for settings pane.")
                // Fallback to opening System Settings main page
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
        }
        Logger.permissions.info("Accessibility Alert: Dismissed (response: \(response.rawValue)).")

        // Re-check state immediately after dismissal, maybe permissions were granted
        // No need for the isShowing flag reset here as runModal was blocking
        isShowingPermissionAlert = false // Reset flag here after alert is gone
        Logger.state.info("Re-determining state after permission alert dismissed.")
        determineStateAndSetupUI(context: "Permission Alert Dismissed")

    }

    private func showWelcomeAlert() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard NSApplication.shared.modalWindow == nil else {
            Logger.ui.warning("Welcome alert skipped: Another modal window (likely an alert) is already visible.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Welcome to \(Bundle.main.appName)!"
        alert.informativeText = "Ready to configure!\n\n1. Click the \(Bundle.main.appName) menu bar icon.\n\n2. Select exactly two keyboard layouts you want to switch between.\n\n3. Press Caps Lock (now acting as a layout switcher) to instantly toggle between them!"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        Logger.ui.info("Displaying Welcome alert.")
        alert.runModal()
        Logger.ui.info("Welcome Alert dismissed.")
    }

    private func showWelcomeMessageIfNeeded() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: PrefKeys.hasShownWelcome) {
             Logger.ui.info("Welcome message needed, showing.")
             showWelcomeAlert() // Assumes this runs modally
             defaults.set(true, forKey: PrefKeys.hasShownWelcome)
        } else {
             Logger.ui.debug("Welcome message already shown previously.")
        }
    }

    // MARK: - Menu Actions (Main Thread)

     @objc func showWelcomeGuideAction() { showWelcomeAlert() }
     @objc func openAccessibilitySettings() {
        // No longer need the isShowing flag management here, showAccessibilityInstructionsAlert handles it
        DispatchQueue.main.async { [weak self] in // Ensure it runs after current event loop cycle
             self?.showAccessibilityInstructionsAlert(triggeredByUserAction: true)
        }
    }

    // MARK: - Status Bar & Menu UI Setup (Main Thread Only)

    private func setupStatusBar() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.ui.debug("Setting up status bar for state: \(self.state.currentOperationalState.description)")

        // Create Status Item if it doesn't exist
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            guard let button = statusItem?.button else { // Check button directly
                Logger.app.critical("Status bar item button creation failed.")
                terminateApp() // Use helper to terminate cleanly
                return
            }
            button.imagePosition = .imageOnly // Ensure only image shows
            Logger.ui.info("Status bar item created.")
        }

        // Create Menu if it doesn't exist
        if appMenu == nil {
           appMenu = NSMenu()
           appMenu?.delegate = self
           appMenu?.autoenablesItems = false // We manage enabled state manually
           statusItem?.menu = appMenu // Assign menu to status item
           Logger.ui.info("App menu created and assigned.")
        }

        // Always clear and rebuild the menu content based on current state
        appMenu?.removeAllItems()
        statusMenuItem = nil // Reset status menu item reference

        updateStatusIcon(for: state.currentOperationalState) // Set the icon

        // Build menu items based on state
        switch state.currentOperationalState {
            case .permissionsRequired:
                let statusItem = NSMenuItem(title: "Permissions Required", action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                appMenu?.addItem(statusItem)
                self.statusMenuItem = statusItem // Store reference if needed later

                appMenu?.addItem(NSMenuItem.separator()) // Separator

                let guideItem = NSMenuItem(title: "Show Permissions Guide", action: #selector(openAccessibilitySettings), keyEquivalent: "")
                guideItem.target = self // Target is self
                guideItem.isEnabled = true
                appMenu?.addItem(guideItem)

            case .configuring, .active:
                // Add status item (title updated in updateMenuState)
                let statusItem = NSMenuItem(title: "Loading Status...", action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                appMenu?.addItem(statusItem)
                self.statusMenuItem = statusItem // Store reference

                appMenu?.addItem(NSMenuItem.separator()) // Separator

                // Placeholder for layout items (added in updateMenuState)
                appMenu?.addItem(NSMenuItem.separator()) // Separator

                // Add common items
                let launchItem = NSMenuItem(title: "Launch on Startup", action: #selector(toggleLaunchOnStartup(_:)), keyEquivalent: "l")
                launchItem.target = self
                launchItem.isEnabled = true // Always enabled if permissions are OK
                appMenu?.addItem(launchItem)

                let welcomeItem = NSMenuItem(title: "Show Welcome Guide", action: #selector(showWelcomeGuideAction), keyEquivalent: "w")
                welcomeItem.target = self
                welcomeItem.isEnabled = true
                appMenu?.addItem(welcomeItem)
        }

        // Add Quit item always
        appMenu?.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit \(Bundle.main.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp // Target is NSApp for terminate
        quitItem.isEnabled = true
        appMenu?.addItem(quitItem)

        Logger.ui.info("Status bar menu rebuilt for state: \(self.state.currentOperationalState.description)")
    }


    private func updateStatusIcon(for operationalState: AppOperationalState) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard let button = statusItem?.button else {
             Logger.ui.error("Cannot update status icon: button is nil")
             return
        }

        let iconName: String
        let accessibilityDescription: String
        let fallbackTitle: String // Use emojis as simple fallbacks

        switch operationalState {
            case .permissionsRequired:
                iconName = "exclamationmark.triangle.fill" // SF Symbol name
                fallbackTitle = "⚠️"
                accessibilityDescription = "\(Bundle.main.appName): Permissions Required"
            case .configuring:
                iconName = "keyboard.badge.ellipsis"
                fallbackTitle = "⚙️" // Gear emoji
                accessibilityDescription = "\(Bundle.main.appName): Configuring - Select Layouts"
            case .active:
                iconName = "keyboard.fill"
                fallbackTitle = "⌨️" // Keyboard emoji
                accessibilityDescription = "\(Bundle.main.appName): Active (Caps Lock Remapped)"
        }

        // Attempt to use SF Symbol first
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) { // Don't set accessibility here, use tooltip/button property
            image.isTemplate = true // Ensures it respects dark/light mode
            button.image = image
            button.title = "" // Clear title when using image
            Logger.ui.debug("Set status icon using SF Symbol: \(iconName)")
        } else {
            // Fallback to text/emoji if symbol not found
            button.image = nil
            button.title = fallbackTitle
            Logger.ui.warning("SF Symbol '\(iconName)' failed. Using fallback text '\(fallbackTitle)'. Check macOS version compatibility.")
        }
        // Set tooltip regardless
        button.toolTip = accessibilityDescription
    }


    private func updateMenuState() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard state.currentOperationalState == .configuring || self.state.currentOperationalState == .active,
              let menu = appMenu else {
            Logger.ui.debug("Skipping menu state update (not in configuring/active state or menu nil)")
            return
        }
        Logger.ui.debug("Updating dynamic menu content (State: \(self.state.currentOperationalState.description))...")

        // Update Status Text
        if let statusItem = self.statusMenuItem { // Use the stored reference
            switch state.currentOperationalState {
            case .active:
                statusItem.title = "Switcher: Active" // Simplified title
            case .configuring:
                statusItem.title = (state.availableSelectionCount == 1) ? "Select 1 more layout..." : "Select 2 layouts..."
            default: // Should not happen based on guard, but good practice
                 statusItem.title = "Status: Unknown"
            }
             Logger.ui.debug("Status menu item text set to: \(statusItem.title)")
        } else {
             Logger.ui.warning("Cannot update status text: statusMenuItem reference is nil.")
        }

        // Update Layout List Items
        updateLayoutMenuItems(in: menu)
    }


    private func updateLayoutMenuItems(in menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Find the separators that bracket the layout items
        // Assumes structure: Status -> Sep -> Layouts... -> Sep -> Options...
        guard let firstSepIndex = menu.items.firstIndex(where: { $0.isSeparatorItem }),
              let secondSep = menu.items[(firstSepIndex + 1)...].first(where: { $0.isSeparatorItem }),
              let secondSepIndex = menu.items.firstIndex(of: secondSep) else {
            Logger.ui.error("Layout separators not found correctly for updateLayoutMenuItems. Menu structure might be wrong.")
            return
        }

        // Remove existing items between the separators
        let rangeToRemove = (firstSepIndex + 1)..<secondSepIndex
        if !rangeToRemove.isEmpty {
            Logger.ui.debug("Removing \(rangeToRemove.count) old layout items between indices \(rangeToRemove.lowerBound) and \(rangeToRemove.upperBound).")
            for i in rangeToRemove.reversed() { // Remove from end to start
                menu.removeItem(at: i)
            }
        } else {
             Logger.ui.debug("No existing layout items found to remove.")
        }

        // Clear the map before rebuilding
        state.menuItemToSourceMap.removeAll()

        let insertIndex = firstSepIndex + 1 // Index where new items will start
        Logger.ui.debug("Adding \(self.state.allSelectableSources.count) new layout items at index \(insertIndex)...")

        // Add items for currently available selectable sources
        for (offset, source) in state.allSelectableSources.enumerated() {
            guard let name = getInputSourceLocalizedName(source), let id = getInputSourceID(source) else {
                Logger.ui.warning("Skipping layout item: Could not get name or ID for a source.")
                continue
            }

            let menuItem = NSMenuItem(title: name, action: #selector(layoutMenuItemSelected(_:)), keyEquivalent: "")
            menuItem.target = self

            // Determine selected state
            let isSelected = (id == state.selectedSourceID1 || id == state.selectedSourceID2)
            menuItem.state = isSelected ? .on : .off

            // Determine enabled state (can select if < 2 already selected, or if deselecting this one)
            let canSelectMore = (state.targetSource1Ref == nil || state.targetSource2Ref == nil) // Check if slots are actually filled
            menuItem.isEnabled = isSelected || canSelectMore

            // Add tooltips for clarity
            menuItem.toolTip = "Keyboard Layout: \(name) (\(id))"

            menu.insertItem(menuItem, at: insertIndex + offset)
            state.menuItemToSourceMap[menuItem] = source // Map item to source object
        }

        // Add instruction text if configuring
        if state.currentOperationalState == .configuring && state.allSelectableSources.isEmpty {
             let noSourcesItem = NSMenuItem(title: "(No keyboard layouts found)", action: nil, keyEquivalent: "")
             noSourcesItem.isEnabled = false
             menu.insertItem(noSourcesItem, at: insertIndex)
        }

        Logger.ui.debug("Layout menu items update complete. \(self.state.menuItemToSourceMap.count) items mapped.")
    }


    // MARK: - Launch on Startup Logic (Using SMAppService)

    // Updated to handle potential SMAppService errors more gracefully
    private func performLaunchOnStartupUpdate(enable: Bool) async -> (status: SMAppService.Status, error: Error?) {
        do {
            if enable {
                try SMAppService.mainApp.register()
                Logger.app.info("Launch on Startup: Registered successfully.")
            } else {
                try await SMAppService.mainApp.unregister() // Ensure await here
                Logger.app.info("Launch on Startup: Unregistered successfully.")
            }
            // Return current status after successful operation, no error
            return (SMAppService.mainApp.status, nil)
        } catch {
            Logger.app.error("Launch on Startup: \(enable ? "Registration" : "Unregistration") failed: \(error.localizedDescription)")
            // Return current status and the error
            return (SMAppService.mainApp.status, error)
        }
    }

    @objc func toggleLaunchOnStartup(_ sender: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        let shouldEnable = (sender.state == .off) // Determine desired state
        let targetSelector = #selector(toggleLaunchOnStartup(_:)) // For finding the item later

        Task(priority: .userInitiated) { // Use userInitiated as it's a direct user action
            // Perform the update and capture the result (status and potential error)
            let result = await performLaunchOnStartupUpdate(enable: shouldEnable)

            // Switch back to the main actor to update the UI safely
            await MainActor.run { [weak self] in
                 self?.updateLaunchOnStartupMenuItem(selector: targetSelector, status: result.status, error: result.error)
            }
        }
     }

    // Update UI based on the result of the SMAppService operation
    private func updateLaunchOnStartupMenuItem(selector: Selector, status: SMAppService.Status, error: Error?) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Update the checkmark state based on the reported status
        if let menuItem = self.appMenu?.items.first(where: { $0.action == selector }) {
            menuItem.state = (status == .enabled) ? .on : .off
            Logger.ui.debug("Launch on Startup menu item state updated to: \(menuItem.state == .on ? "ON" : "OFF") (Status: \(status.rawValue))")
        } else {
             Logger.ui.error("Could not find Launch on Startup menu item to update state.")
        }

        // Show an alert if an error occurred
        if let error = error {
            Logger.ui.error("Presenting Launch on Startup error alert.")
            // Avoid showing if another alert is up
            guard NSApplication.shared.modalWindow == nil else {
                 Logger.ui.warning("Skipped Launch on Startup error alert: Another modal window (likely an alert) is visible.")
                 return
            }
            let alert = NSAlert()
            alert.messageText = "Launch on Startup Error"
            alert.informativeText = "Could not update the 'Launch on Startup' setting.\n\nError: \(error.localizedDescription)\n\nYou may need to manage this manually in System Settings > General > Login Items."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
     }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        Logger.ui.debug("Menu Will Open...")
        // Always run the full state check when menu opens to ensure UI is correct
        determineStateAndSetupUI(context: "MenuOpen")
        // Update launch item state *after* determineState sets up the menu
        if state.currentOperationalState == .configuring || state.currentOperationalState == .active {
            updateLaunchOnStartupItemState(menu) // Update based on current SMAppService status
        }
    }

    // Helper to specifically update the launch item state when menu opens
    private func updateLaunchOnStartupItemState(_ menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Find the specific menu item
        if let launchItem = menu.items.first(where: { $0.action == #selector(toggleLaunchOnStartup(_:)) }) {
            let currentStatus = SMAppService.mainApp.status // Get current status
            launchItem.state = (currentStatus == .enabled) ? .on : .off // Set checkmark
            Logger.ui.debug("Launch item state refreshed on menu open: \(launchItem.state == .on ? "ON" : "OFF")")
        }
    }


    // MARK: - Input Source (TIS) Handling (Main Thread Only)

    private func fetchAllSelectableSources() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Define filter properties for TIS
        let filter = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as String, // Use as String
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as String, // Use as String
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue! // Use CFBoolean literal
        ] as CFDictionary // Explicitly cast to CFDictionary

        // Create the list
        guard let sourcesListUntyped = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else {
            Logger.settings.error("TISCreateInputSourceList returned nil. Cannot fetch input sources.")
            state.allSelectableSources = []
            return
        }

        // Cast to Swift array
        guard let sourcesList = sourcesListUntyped as? [TISInputSource] else {
            Logger.settings.error("Could not cast CFArray of input sources to [TISInputSource].")
            state.allSelectableSources = []
            return
        }

        // Filter out any potentially problematic sources (e.g., "null" layout if seen)
        state.allSelectableSources = sourcesList.filter { source in
            if let id = getInputSourceID(source), id.lowercased() == "null" {
                 Logger.settings.warning("Filtering out source with ID 'null'.")
                 return false
            }
            // Also ensure it has a valid localized name
            if getInputSourceLocalizedName(source) == nil {
                Logger.settings.warning("Filtering out source without a localized name (ID: \(self.getInputSourceID(source) ?? "N/A")).")
                return false
            }
            return true
        }

        Logger.settings.debug("Fetched \(self.state.allSelectableSources.count) valid, selectable keyboard layouts.")
     }

    private func updateActiveTargetRefsAndAvailabilityCount() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        // Reset refs and count before checking
        state.targetSource1Ref = nil
        state.targetSource2Ref = nil
        state.availableSelectionCount = 0

        let id1 = state.selectedSourceID1
        let id2 = state.selectedSourceID2

        // If neither ID is set, we're done.
        guard id1 != nil || id2 != nil else {
            Logger.state.debug("No layouts selected in UserDefaults, available count is 0.")
            return
        }

        var count = 0
        var foundRef1: TISInputSource? = nil
        var foundRef2: TISInputSource? = nil

        // Iterate through all *currently enabled* sources
        for source in state.allSelectableSources {
            guard let sourceID = getInputSourceID(source) else { continue } // Skip if source has no ID

            // Check if this source matches one of our selected IDs
            if sourceID == id1 {
                foundRef1 = source
                count += 1
                Logger.state.debug("Found match for selected ID 1: \(id1!)")
            } else if sourceID == id2 { // Use 'else if' assuming IDs are unique
                foundRef2 = source
                count += 1
                 Logger.state.debug("Found match for selected ID 2: \(id2!)")
            }

            // Optimization: If we've found both, no need to check further
            if foundRef1 != nil && foundRef2 != nil {
                 break
            }
        }

        // Update the state
        state.targetSource1Ref = foundRef1
        state.targetSource2Ref = foundRef2
        // Crucially, availableSelectionCount is how many *selected* layouts are *currently usable*
        state.availableSelectionCount = count

        // Log mismatches if an ID was selected but no matching source was found
        if id1 != nil && foundRef1 == nil {
             Logger.state.warning("Selected layout ID '\(id1!)' is not currently enabled or available.")
        }
        if id2 != nil && foundRef2 == nil {
             Logger.state.warning("Selected layout ID '\(id2!)' is not currently enabled or available.")
        }

        Logger.state.info("Updated available selection count: \(count). (Ref1: \(foundRef1 != nil), Ref2: \(foundRef2 != nil))")
     }


    @objc func layoutMenuItemSelected(_ sender: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.ui.info("Layout Item Selected: '\(sender.title)' (Current state: \(sender.state == .on ? "ON" : "OFF"))")

        guard let selectedSource = state.menuItemToSourceMap[sender],
              let selectedID = getInputSourceID(selectedSource) else {
            Logger.ui.error("Could not find TISInputSource or ID for selected menu item: '\(sender.title)'. Bailing out.")
            NSSound.beep() // User feedback
            return
        }

        let userDefaults = UserDefaults.standard
        let wasSelected = (sender.state == .on) // Was it checked *before* the click?

        if wasSelected {
            // --- DESELECTING ---
            Logger.ui.debug("Deselecting layout: \(selectedID)")
            var selectionChanged = false
            if state.selectedSourceID1 == selectedID {
                state.selectedSourceID1 = nil
                userDefaults.removeObject(forKey: PrefKeys.selectedSourceID1)
                Logger.settings.info("Removed selectedSourceID1 (\(selectedID))")
                selectionChanged = true
            } else if state.selectedSourceID2 == selectedID {
                state.selectedSourceID2 = nil
                userDefaults.removeObject(forKey: PrefKeys.selectedSourceID2)
                Logger.settings.info("Removed selectedSourceID2 (\(selectedID))")
                selectionChanged = true
            } else {
                 // This case should ideally not happen if UI state is correct
                Logger.ui.warning("Layout '\(selectedID)' was checked (ON) but didn't match stored ID1 ('\(self.state.selectedSourceID1 ?? "nil")') or ID2 ('\(self.state.selectedSourceID2 ?? "nil")'). Deselecting from UserDefaults anyway.")
                 // Attempt to clear just in case state was inconsistent
                 if userDefaults.string(forKey: PrefKeys.selectedSourceID1) == selectedID { userDefaults.removeObject(forKey: PrefKeys.selectedSourceID1)}
                 if userDefaults.string(forKey: PrefKeys.selectedSourceID2) == selectedID { userDefaults.removeObject(forKey: PrefKeys.selectedSourceID2)}
                 selectionChanged = true // Assume change happened
            }
            if !selectionChanged {
                Logger.ui.warning("Deselection attempted for \(selectedID), but no change was made to stored IDs.")
            }

        } else {
            // --- SELECTING ---
            // Recalculate available slots based on current state *before* assigning
            // This uses the *live* TIS Refs, which is more accurate than just checking IDs
            let slot1Filled = state.targetSource1Ref != nil
            let slot2Filled = state.targetSource2Ref != nil
            let totalFilledSlots = (slot1Filled ? 1 : 0) + (slot2Filled ? 1 : 0)

            guard totalFilledSlots < 2 else {
                Logger.ui.warning("Cannot select more than 2 layouts. Currently filled: \(totalFilledSlots). Beeping.")
                NSSound.beep()
                return // Already have 2 valid selections
            }

            // Assign to the first available slot (prefer slot 1)
            if !slot1Filled {
                Logger.ui.debug("Selecting for Slot 1: \(selectedID)")
                state.selectedSourceID1 = selectedID
                userDefaults.set(selectedID, forKey: PrefKeys.selectedSourceID1)
                 Logger.settings.info("Set selectedSourceID1 = \(selectedID)")
            } else if !slot2Filled { // Only try slot 2 if slot 1 is already filled
                 Logger.ui.debug("Selecting for Slot 2: \(selectedID)")
                 state.selectedSourceID2 = selectedID
                 userDefaults.set(selectedID, forKey: PrefKeys.selectedSourceID2)
                 Logger.settings.info("Set selectedSourceID2 = \(selectedID)")
            } else {
                 // This case should be caught by the 'totalFilledSlots < 2' guard
                 Logger.ui.error("Logic Error: Tried to select layout \(selectedID) but both slots seem filled despite guard passing.")
                 NSSound.beep()
                 return
            }
        }

        // Persist changes immediately
        userDefaults.synchronize()

        // Crucially, re-run the state determination logic to update everything
        Logger.ui.info("Re-determining state after layout selection change for ID: \(selectedID)")
        // Use a specific context
        determineStateAndSetupUI(context: wasSelected ? "LayoutDeselected" : "LayoutSelected")

     }

    // MARK: - Event Tap Lifecycle (Main Thread for Setup/Teardown)

    private func setupEventTap() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard state.eventTap == nil else {
            Logger.eventTap.debug("Tap setup skipped: Tap already exists.")
            return
        }
        // Check permissions again right before creating, though state logic should ensure this
        guard checkAccessibilityPermissions(promptUserIfNeeded: false) else {
            Logger.eventTap.warning("Tap setup skipped: Permissions missing at time of setup.")
            // Ensure state reflects this if it somehow got here
            if state.currentOperationalState != .permissionsRequired {
                Logger.state.warning("State mismatch: setupEventTap called without permissions, forcing state update.")
                determineStateAndSetupUI(context: "Tap Setup Permission Fail")
            }
            return
        }

        Logger.eventTap.info("Creating synchronous event tap (Listening for VK=\(self.triggerKeyCode))...")
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) // Only listen for KeyDown

        // Pass self as userInfo (refcon)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Create the tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, // Monitor system-wide events
            place: .headInsertEventTap, // Insert tap early
            options: .listenOnly, // Change to .listenOnly initially, callback decides consumption
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            Logger.eventTap.critical("Failed to create event tap! Switching will not work.")
            // This is critical, maybe try to revert state?
             determineStateAndSetupUI(context: "Event Tap Creation Failed")
            return
        }
        Logger.eventTap.debug("CGEvent.tapCreate successful.")

        // Create the run loop source
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Logger.eventTap.critical("Failed to create run loop source for event tap!")
            // Tap was created but source failed, need to invalidate the tap
            CFMachPortInvalidate(tap) // Clean up the created tap port
            determineStateAndSetupUI(context: "RunLoop Source Creation Failed")
            return
        }
         Logger.eventTap.debug("CFMachPortCreateRunLoopSource successful.")

        // Add source to the current run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        Logger.eventTap.debug("Run loop source added to current run loop for common modes.")

        // Store references
        state.eventTap = tap
        state.runLoopSource = runLoopSource

        // Enable the tap (start listening)
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
             Logger.eventTap.info("Synchronous event tap created, added to run loop, and ENABLED.")
        } else {
             Logger.eventTap.error("Event tap created and added, but FAILED TO ENABLE.")
             // Clean up if enable failed
             destroyEventTap()
             determineStateAndSetupUI(context: "Event Tap Enable Failed")
        }
     }

    private func destroyEventTap() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard let tap = state.eventTap, let source = state.runLoopSource else {
             Logger.eventTap.debug("Destroy event tap skipped: No tap or source found in state.")
             return
        }
        Logger.eventTap.info("Destroying event tap...")

        // Check if tap is valid before trying to disable/invalidate
        // Note: CFMachPortIsValid might not be reliable after invalidation elsewhere. Rely on tapEnable state.
        if CGEvent.tapIsEnabled(tap: tap) {
             CGEvent.tapEnable(tap: tap, enable: false)
             Logger.eventTap.debug("Event tap disabled.")
        } else {
             Logger.eventTap.debug("Event tap was already disabled.")
        }

        // Remove source from run loop *before* invalidating the tap
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        Logger.eventTap.debug("Run loop source removed.")

        // Invalidate the tap port itself - releases resources associated with the tap
        // Note: According to docs, CFMachPortInvalidate does not release the userInfo pointer.
        // Since we used Unmanaged.passUnretained, this is correct behavior.
        // CFMachPortInvalidate(tap) // This might be redundant if tapEnable(false) cleans up enough, test carefully.
        // Let's keep invalidate for good measure if it doesn't cause issues.
        // Update: Let's try *without* explicit invalidate first, as tapEnable(false) and removing source *should* be enough.
        // Re-add CFMachPortInvalidate(tap) if issues arise with tap recreation.

        // Clear state references
        state.eventTap = nil
        state.runLoopSource = nil
        Logger.eventTap.info("Event tap destroyed and state references cleared.")
     }

    // MARK: - Helper Functions (Main Thread Safe unless noted)

    /// Safely gets the Input Source ID (e.g., "com.apple.keylayout.US")
    private func getInputSourceID(_ source: TISInputSource) -> String? {
        // Use TISGetInputSourceProperty which returns UnsafeMutableRawPointer?
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
             Logger.settings.warning("TISGetInputSourceProperty returned nil for kTISPropertyInputSourceID")
             return nil
        }
        // Cast the pointer to the expected CFType (CFString)
        let cfString = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        // Bridge to Swift String
        return cfString as String
    }

    /// Safely gets the Input Source Localized Name (e.g., "U.S.")
    private func getInputSourceLocalizedName(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            Logger.settings.warning("TISGetInputSourceProperty returned nil for kTISPropertyLocalizedName (ID: \(self.getInputSourceID(source) ?? "N/A"))")
             return nil
        }
        let cfString = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        return cfString as String
    }

    /// Helper to cleanly terminate the application.
    private func terminateApp() {
        Logger.app.critical("Terminating application NOW due to critical error!")
        // Ensure cleanup runs on main thread if called from elsewhere (though usually won't be)
        DispatchQueue.main.async {
            // Explicitly try to revert HID mapping one last time
            self.manageHidRemapping(enable: false, context: "Critical Terminate")
            self.destroyEventTap() // Clean up tap
            self.permissionCheckTimer?.invalidate() // Stop timer
            NSApplication.shared.terminate(self) // Terminate
        }
    }

} // End of AppDelegate class

// MARK: - Bundle Extension

extension Bundle {
    var appName: String {
        // Prefer display name, fallback to bundle name, then a default
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        object(forInfoDictionaryKey: "CFBundleName") as? String ??
        "CapsLockSwitcher"
    }
}

// MARK: - NSAlertPanel Helper (Example of checking for existing alerts)
// Note: This uses internal class name, might be fragile across OS versions. Use with caution.
extension NSApplication {
    var isAlertShowing: Bool {
        // Check if any window is an instance of the private NSAlertPanel class
        return self.windows.contains { $0.className == "NSAlertPanel" }
    }
}


// MARK: - main.swift Entry Point (Assumed to be separate)
/*
 // main.swift
 import Cocoa

 // Create the application instance
 let app = NSApplication.shared

 // Create the AppDelegate
 let delegate = AppDelegate()
 app.delegate = delegate

 // Start the main event loop
 app.run()

 */
