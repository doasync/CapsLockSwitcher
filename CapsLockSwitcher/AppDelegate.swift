import Cocoa
import InputMethodKit // For TIS... functions
import Carbon.HIToolbox // For kVK_ constants and TIS... alternative access
import Accessibility // For AXIsProcessTrustedWithOptions
import ServiceManagement // For SMAppService (Login Items) - Requires macOS 13+

// --- Global Scope for C Callback ---
// The CGEventTap callback needs to be a C function pointer.
// We pass 'self' (AppDelegate instance) as the userInfo pointer
// to bridge back into the Swift class context.
private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        print("Error: refcon is nil in eventTapCallback")
        return Unmanaged.passRetained(event)
    }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return delegate.handleEventTap(proxy: proxy, type: type, event: event)
}

// --- AppDelegate Class ---
// No @main needed because we use main.swift (required)
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // --- Constants ---
    private enum PrefKeys {
        static let selectedSourceID1 = "selectedSourceID1"
        static let selectedSourceID2 = "selectedSourceID2"
        static let hasShownWelcome = "hasShownWelcome"
    }
    private let capsLockKeyCode = CGKeyCode(kVK_CapsLock) // 57

    // --- Application Operational State ---
    private enum AppOperationalState {
        case permissionsRequired
        case configuring // Permissions OK, but < 2 layouts selected/active
        case active      // Permissions OK, 2 layouts selected/active
    }

    // --- UI Elements ---
    private var statusItem: NSStatusItem?
    private var appMenu: NSMenu?
    private var statusMenuItem: NSMenuItem? // To show current status/instructions

    // --- State Management ---
    private struct AppState {
        var selectedSourceID1: String? = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID1)
        var selectedSourceID2: String? = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID2)
        var targetSource1Ref: TISInputSource? = nil
        var targetSource2Ref: TISInputSource? = nil
        var availableSelectionCount: Int = 0
        var allSelectableSources: [TISInputSource] = []
        var menuItemToSourceMap: [NSMenuItem: TISInputSource] = [:]
        var eventTap: CFMachPort? = nil
        var runLoopSource: CFRunLoopSource? = nil
        var isTapEnabled = false // Reflects if switching logic should execute (derived from count)
        var currentOperationalState: AppOperationalState = .permissionsRequired
        var isShowingConfigurationAlert = false // Debounce configuration alert
        var isShowingPermissionAlert = false    // Debounce permission alert
    }
    private var state = AppState()

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("CapsLockSwitcher: Did Finish Launching")

        // Set the override
        manageCapsLockDelayOverride(setOverride: true)

        // Check permissions initially - prompt might not work on modern OS anyway
        let hasPermissions = checkAccessibilityPermissions(promptUserIfNeeded: false)

        if hasPermissions {
            print("CapsLockSwitcher: Accessibility permissions granted at launch.")
            state.currentOperationalState = .configuring // Start as configuring
            setupStatusBar() // Setup full menu structure
            setupEventTap()  // Attempt to create the tap
            if state.eventTap != nil { // Check if tap creation succeeded
                showWelcomeMessageIfNeeded() // Show only once after initial grant/setup
                fetchAllSelectableSources()
                updateActiveTargetRefsAndAvailabilityCount() // Calculate count, update internal tap flag
                updateMenuState() // Update menu content & icon based on count
            } else {
                // Tap setup failed even though permissions reported OK
                print("Warning: Tap setup failed despite reported permissions. Reverting state.")
                state.currentOperationalState = .permissionsRequired
                setupStatusBar() // Rebuild limited menu
                // Show alert again to guide user
                DispatchQueue.main.async {
                    self.showAccessibilityInstructionsAlert(triggeredByUserAction: false)
                }
            }
        } else {
            // No permissions at launch
            print("CapsLockSwitcher: Accessibility permissions not granted at launch.")
            state.currentOperationalState = .permissionsRequired
            setupStatusBar() // Setup limited menu structure
            // Show alert automatically to guide the user first time
            DispatchQueue.main.async {
                self.showAccessibilityInstructionsAlert(triggeredByUserAction: false)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("CapsLockSwitcher: Will Terminate")
        manageCapsLockDelayOverride(setOverride: false) // Reset the override
        destroyEventTap() // Clean up the event tap
        // Remove status item (optional, system usually does it)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - Accessibility Permissions

    /// Checks if the process has Accessibility permissions.
    private func checkAccessibilityPermissions(promptUserIfNeeded: Bool) -> Bool {
        // Using deprecated AXIsProcessTrustedWithOptions for simplicity here.
        // Modern approach involves async methods or monitoring notifications.
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: promptUserIfNeeded] as CFDictionary
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        // print("checkAccessibilityPermissions: \(accessEnabled)") // Debug log
        return accessEnabled
    }

    /// Shows an alert guiding the user to grant Accessibility permissions.
    /// - Parameter triggeredByUserAction: True if the user clicked the menu item, false if shown automatically or via event tap.
    private func showAccessibilityInstructionsAlert(triggeredByUserAction: Bool) {
        // Prevent showing multiple alerts simultaneously if already presenting
        guard !(NSApp.modalWindow?.isVisible ?? false) else {
            print("Accessibility Instructions Alert: Already presenting another modal.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        // Use the updated informative text
        alert.informativeText = "\(Bundle.main.appName) needs Accessibility access to monitor the Caps Lock key.\n\nPlease go to System Settings > Privacy & Security > Accessibility, find and enable \(Bundle.main.appName) or add it manually using the '+' button."

        // Add context based on how the alert was triggered
        if !triggeredByUserAction {
            alert.informativeText += "\n\nAfter granting permissions, click the menu bar icon to activate."
        } else {
            // If triggered by menu click, the context is slightly different
            alert.informativeText += "\n\nIf it's enabled but not working, try removing the old version using the '-' button, then add it back again."
            alert.informativeText += "\n\nAfter granting permissions, click the menu bar icon again to continue setup."
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        // Removed OK button

        print("CapsLockSwitcher: Displaying Accessibility Instructions Alert.")
        let response = alert.runModal() // This blocks the main thread here until dismissed

        if response == .alertFirstButtonReturn {
            // Open System Settings > Security & Privacy > Accessibility
            let privacyUrl = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(privacyUrl)
            print("Accessibility Instructions Alert: Opened settings, app remains running.")
        }
        // No else needed as there's only one button action now

        // --- DO NOT reset isShowingPermissionAlert flag here ---
        // The flag reset happens in the dispatch block in handleEventTap *after* this runModal call returns.
        print("Accessibility Instructions Alert: Alert dismissed.")
    }

    // MARK: - Welcome Guide
    /// Actually displays the welcome alert.
    private func showWelcomeAlert() {
        guard !(NSApp.modalWindow?.isVisible ?? false) else {
            print("Welcome Alert: Already presenting another modal.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Welcome to \(Bundle.main.appName)!"
        alert.informativeText = "Setup complete!\n\n1. Click the \(Bundle.main.appName) menu bar icon.\n\n2. Select exactly two keyboard layouts you want to switch between using Caps Lock.\n\n3. Press Caps Lock to instantly toggle between them!"
        alert.alertStyle = .informational
        print("CapsLockSwitcher: Displaying welcome alert.")
        alert.runModal() // Dismisses automatically without buttons
    }

    /// Checks if the welcome message should be shown (e.g., first time) and shows it.
    private func showWelcomeMessageIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: PrefKeys.hasShownWelcome) {
             print("CapsLockSwitcher: Welcome message needed, showing automatically.")
             showWelcomeAlert() // Call the function that actually shows it
             // Mark as shown so it doesn't show automatically again
             defaults.set(true, forKey: PrefKeys.hasShownWelcome)
             defaults.synchronize() // Ensure saved immediately
        } else {
             print("CapsLockSwitcher: Welcome message already shown previously.")
        }
    }

    /// Action for the "Show Welcome Guide" menu item.
    @objc func showWelcomeGuideAction() {
         print("CapsLockSwitcher: 'Show Welcome Guide' menu item clicked.")
         // Directly call the alert display function, bypassing the "shown before" check
         showWelcomeAlert()
    }

    /// Action for the "Show Permissions Guide" menu item.
    @objc func openAccessibilitySettings() {
        // This is always triggered by user action (clicking the menu)
        showAccessibilityInstructionsAlert(triggeredByUserAction: true)
    }


    // MARK: - Status Bar & Menu Setup
    /// Sets up the status bar item and its menu based on the current state. Rebuilds if called again.
    private func setupStatusBar() {
        // Ensure status item exists or create it
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            guard statusItem != nil else {
                print("Error: Could not create status bar item.")
                terminateApp(); return
            }
        }
        // Ensure button exists (check only, no assignment needed here)
        guard statusItem?.button != nil else {
            print("Error: Could not access status bar button.")
            return
        }

        // --- Clear Existing Menu Items ---
        appMenu?.removeAllItems() // Clear previous menu if it exists
        if appMenu == nil {
           appMenu = NSMenu()
           appMenu?.delegate = self
           appMenu?.autoenablesItems = false // IMPORTANT for manual state control
        }
        // Reassign menu in case it was recreated or cleared
        statusItem?.menu = appMenu


        // --- Set Icon based on CURRENT state.currentOperationalState ---
        // This state should have been updated *before* calling setupStatusBar
        updateStatusIcon(for: state.currentOperationalState)

        // --- Build Menu Items based on state ---
        if state.currentOperationalState == .permissionsRequired {
            print("setupStatusBar: Building limited menu (Permissions Required).")
            // 1. Status Text Item (Greyed Out)
            statusMenuItem = NSMenuItem(title: "Permissions are required", action: nil, keyEquivalent: "") // No action
            statusMenuItem?.isEnabled = false // Greyed out
            appMenu?.addItem(statusMenuItem!)
            // 2. Permissions Guide Button (Enabled)
            let guideMenuItem = NSMenuItem(title: "Show Permissions Guide", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            guideMenuItem.target = self
            appMenu?.addItem(guideMenuItem)
            // 3. Separator (BEFORE Quit)
            appMenu?.addItem(NSMenuItem.separator())
            // 4. Quit Item
            let quitItem = NSMenuItem(title: "Quit \(Bundle.main.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quitItem.target = NSApp
            appMenu?.addItem(quitItem)
        } else {
            // --- Full Menu Build (Configuring/Active) ---
            print("setupStatusBar: Building full menu (Configuring/Active).")
            // 1. Status Item (dynamic text)
            statusMenuItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            statusMenuItem?.isEnabled = false
            appMenu?.addItem(statusMenuItem!)
            // 2. Separator before layouts
            appMenu?.addItem(NSMenuItem.separator())
            // --- Dynamic Layout Items Added Here by updateMenuState ---
            // 3. Separator after layouts
            appMenu?.addItem(NSMenuItem.separator())
            // 4. Launch on Startup Item
            let launchOnStartupMenuItem = NSMenuItem(title: "Launch on Startup", action: #selector(toggleLaunchOnStartup(_:)), keyEquivalent: "l")
            launchOnStartupMenuItem.target = self
            // Initial checkmark state set in menuWillOpen
            appMenu?.addItem(launchOnStartupMenuItem)
            // 5. Welcome Guide Item
            let welcomeMenuItem = NSMenuItem(title: "Show Welcome Guide", action: #selector(showWelcomeGuideAction), keyEquivalent: "w")
            welcomeMenuItem.target = self
            appMenu?.addItem(welcomeMenuItem)
            // 6. Separator before quit
            appMenu?.addItem(NSMenuItem.separator())
            // 7. Quit Item
            let quitItem = NSMenuItem(title: "Quit \(Bundle.main.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quitItem.target = NSApp
            appMenu?.addItem(quitItem)
        }
        print("CapsLockSwitcher: Status bar item and menu configured for state: \(state.currentOperationalState).")
    }

    /// Helper function to update the Status Bar Icon and internal state.
    private func updateStatusIcon(for operationalState: AppOperationalState) {
        guard let button = statusItem?.button else { return }
        let iconName: String, fallbackTitle: String, accessibilityDescription: String

        switch operationalState {
        case .permissionsRequired:
            iconName = "exclamationmark.triangle.fill"; fallbackTitle = "⚠️"; accessibilityDescription = "Permissions Required"
        case .configuring:
            iconName = "keyboard.badge.ellipsis"; fallbackTitle = "⌨️"; accessibilityDescription = "Configuring - Select Layouts" // Updated icon
        case .active:
            iconName = "keyboard.fill"; fallbackTitle = "⌨️"; accessibilityDescription = "Active" // Reverted to filled icon for Active
        }

        // Update internal state *before* updating UI visuals if needed
        if state.currentOperationalState != operationalState {
            state.currentOperationalState = operationalState
            print("CapsLockSwitcher: Operational state updated to: \(operationalState)")
        }

        // Update button appearance
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "CapsLock Switcher Status: \(accessibilityDescription)") {
            button.image = image; button.image?.isTemplate = true; button.title = ""
        } else {
            button.image = nil; button.title = fallbackTitle
            print("Warning: Could not load SF Symbol '\(iconName)'. Using text fallback '\(fallbackTitle)'.")
        }
        button.toolTip = "CapsLockSwitcher: \(accessibilityDescription)" // Add tooltip for clarity
    }

    // MARK: - Launch on Startup (Requires macOS 13+)
    
    /// Action method for the "Launch on Startup" menu item
    @objc func toggleLaunchOnStartup(_ sender: NSMenuItem) {
        let initialStatus = SMAppService.mainApp.status // Get current status sync

        // Define the selector we'll use to find the item later on the main thread
        let targetSelector = #selector(toggleLaunchOnStartup(_:))

        // Perform potentially blocking/background operation within a Task
        Task {
            // Variables to hold the results determined in this Task
            var resultingState: NSControl.StateValue = .off // Default state on failure or if disabled
            var operationError: Error? = nil               // To capture any thrown error

            do {
                if initialStatus == .enabled {
                    print("Launch on Startup: Currently enabled, attempting to unregister...")
                    // Use 'try' only, remove 'await'
                    try SMAppService.mainApp.unregister()
                    print("Launch on Startup: Unregistered successfully.")
                    resultingState = .off // If unregister succeeded, desired state is off
                } else {
                    print("Launch on Startup: Currently disabled (\(initialStatus)), attempting to register...")
                    // Use 'try' only, remove 'await'
                    try SMAppService.mainApp.register()
                    print("Launch on Startup: Registered successfully.")
                    resultingState = .on // If register succeeded, desired state is on
                }
            } catch {
                // Capture the error if one occurred
                operationError = error
                print("Failed to update Launch on Startup setting: \(error.localizedDescription)")
                // If an error occurred, query the *actual* status again
                // to set the checkmark correctly based on reality.
                let actualStatusAfterError = SMAppService.mainApp.status
                resultingState = (actualStatusAfterError == .enabled) ? .on : .off
            }

            // --- Safely Update UI on Main Thread ---
            // Capture the results (basic types are safe)
            let finalState = resultingState
            let finalError = operationError // Error type is generally Sendable

            DispatchQueue.main.async {
                // Find the menu item *again* on the main thread using its selector
                // Use optional chaining on appMenu in case it's somehow nil
                if let menuItem = self.appMenu?.items.first(where: { $0.action == targetSelector }) {
                    // Update the state of the found menu item
                    menuItem.state = finalState
                    print("Launch on Startup: UI updated to state \(finalState == .on ? "ON" : "OFF")")
                } else {
                    // Log if the item couldn't be found (shouldn't happen normally)
                    print("Error: Could not find 'Launch on Startup' menu item on main thread to update UI state.")
                }

                // Optionally, show an alert to the user if an error occurred
                if let error = finalError {
                    // You could display an NSAlert here informing the user about the failure
                    print("Error occurred during Launch on Startup operation (logged previously). Consider showing user alert.")

                    let alert = NSAlert()
                    alert.messageText = "Launch Setting Error"
                    alert.informativeText = "Failed to update the 'Launch on Startup' setting:\n\(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
        // Note: This @objc function returns immediately after launching the Task.
        // The actual registration/unregistration and UI update happen asynchronously.
    }

    // MARK: - NSMenuDelegate

    /// Called just before the menu is displayed. Handles state transitions and content refresh.
    func menuWillOpen(_ menu: NSMenu) {
        print("CapsLockSwitcher: Menu Will Open - Checking State...")
        // 1. Check current permission status WITHOUT prompting
        let hasPermissionsNow = checkAccessibilityPermissions(promptUserIfNeeded: false)

        // --- Handle Losing Permissions ---
        if !hasPermissionsNow {
            print("CapsLockSwitcher: Permissions detected as MISSING!")
            // Immediately destroy the event tap if it exists to prevent input freezes.
            if state.eventTap != nil {
                print("CapsLockSwitcher: Destroying event tap due to permission loss.")
                destroyEventTap()
            }
            // Ensure UI reflects the required state. Check if update is needed.
            if state.currentOperationalState != .permissionsRequired {
                 print("CapsLockSwitcher: Transitioning internal state to Permissions Required.")
                 state.currentOperationalState = .permissionsRequired // Set state FIRST
                 setupStatusBar() // Rebuilds UI based on new state
            } else {
                 print("CapsLockSwitcher: State already Permissions Required. Ensuring UI consistency.")
                 setupStatusBar() // Rebuild to be safe
            }
            // Stop further processing in this method
            return
        }

        // --- Handle Gaining Permissions (or Staying Permitted) ---
        // Only proceed here if hasPermissionsNow is TRUE

        // 2. Handle State Transition: Permissions were missing, but now granted
        if state.currentOperationalState == .permissionsRequired {
            print("CapsLockSwitcher: Permissions detected as granted! Transitioning state...")
            state.currentOperationalState = .configuring // Set tentative state
            setupStatusBar() // Rebuilds full menu, sets configuring icon
            setupEventTap()  // Create and enable the tap

            if state.eventTap != nil {
                 showWelcomeMessageIfNeeded() // Show welcome on first successful grant
                 fetchAllSelectableSources()
                 updateActiveTargetRefsAndAvailabilityCount() // Updates internal tap flag
                 updateMenuState() // Updates menu content & potentially sets .active icon
                 print("CapsLockSwitcher: State transitioned successfully.")
            } else {
                 print("Error: Tap setup failed after permissions granted. Reverting UI state.")
                 state.currentOperationalState = .permissionsRequired // Revert state
                 setupStatusBar() // Revert to limited menu/icon
                 DispatchQueue.main.async { // Show alert again
                     self.showAccessibilityInstructionsAlert(triggeredByUserAction: true)
                 }
            }
            // Set initial launch item state after potential menu rebuild
            updateLaunchOnStartupItemState(menu)
            return // Stop processing, menu is rebuilt/updated
        }

        // 3. Normal Refresh: App already has permissions and was in configuring/active state
        print("CapsLockSwitcher: Permissions OK, refreshing menu content and startup state.")
        fetchAllSelectableSources()
        updateActiveTargetRefsAndAvailabilityCount() // Updates internal tap flag
        updateMenuState() // Updates menu content and icon based on count
        updateLaunchOnStartupItemState(menu) // Update launch item state
    }

    /// Helper to update the Launch on Startup menu item's checkmark state.
    private func updateLaunchOnStartupItemState(_ menu: NSMenu) {
        // Find the menu item (safer than assuming index)
        if let launchItem = menu.items.first(where: { $0.action == #selector(toggleLaunchOnStartup(_:)) }) {
            let currentStatus = SMAppService.mainApp.status
            launchItem.state = (currentStatus == .enabled) ? .on : .off
            // print("Launch on Startup: Initial checkmark state set to \(launchItem.state == .on ? "ON" : "OFF") based on status \(currentStatus)")
        } else {
             // This might happen briefly if menu is rebuilt for permissions required state
             // print("Debug: Could not find 'Launch on Startup' menu item to update state (normal if permissions required).")
        }
    }


    // MARK: - Input Source Handling (TIS)

    /// Fetches all currently enabled, selectable keyboard input sources.
    private func fetchAllSelectableSources() {
        // Define filter using Swift types where possible for clarity
        let filterDict: [String: Any] = [
            (kTISPropertyInputSourceType as String): kTISTypeKeyboardLayout as String,
            (kTISPropertyInputSourceIsSelectCapable as String): true
        ]
        // Cast the Swift dictionary to CFDictionary when calling the C function
        guard let sourcesList = TISCreateInputSourceList(filterDict as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            print("Error: Could not fetch input sources.")
            state.allSelectableSources = []
            return
        }
        // Filter out non-keyboard types just in case filter wasn't perfect
        state.allSelectableSources = sourcesList.filter { source in
            guard let categoryPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { return false }
            let category = Unmanaged<CFString>.fromOpaque(categoryPtr).takeUnretainedValue() as String
            return category == (kTISCategoryKeyboardInputSource as String)
        }
    }

    /// Updates the targetSource Refs and count based on current availability and persisted IDs. Also updates the internal tap enabled flag.
    private func updateActiveTargetRefsAndAvailabilityCount() {
        state.targetSource1Ref = nil; state.targetSource2Ref = nil; state.availableSelectionCount = 0
        let id1 = state.selectedSourceID1; let id2 = state.selectedSourceID2
        guard id1 != nil || id2 != nil else { updateTapEnabledState(); return } // Ensure flag updated even if no selections

        for source in state.allSelectableSources {
            guard let sourceID = getInputSourceID(source) else { continue }
            if sourceID == id1 { state.targetSource1Ref = source; state.availableSelectionCount += 1 }
            else if sourceID == id2 { state.targetSource2Ref = source; state.availableSelectionCount += 1 }
        }
        print("CapsLockSwitcher: Active selected layouts count: \(state.availableSelectionCount)")
        updateTapEnabledState() // Update internal flag based on count
    }

    /// Updates the visual state of the menu items (status, checkmarks, enabled state) and status bar icon.
    private func updateMenuState() {
        guard let menu = appMenu, let statusItem = statusMenuItem, state.currentOperationalState != .permissionsRequired else { return }

        // Determine target state and update icon/status text
        let targetState: AppOperationalState
        switch state.availableSelectionCount {
        case 2:
            targetState = .active
            // Simplified status text
            statusItem.title = "Switcher: Active"
        case 1:
            targetState = .configuring
            statusItem.title = "Select 1 more layout..."
        default: // 0
            targetState = .configuring
            statusItem.title = "Select 2 layouts..."
        }
        updateStatusIcon(for: targetState) // Update icon to match selection state


        // --- Remove Old Layout Items ---
         guard let firstSeparator = menu.items.first(where: { $0.isSeparatorItem }), // Should be the one after the status item
               let secondSeparator = menu.items.first(where: { $0.isSeparatorItem && $0 != firstSeparator }), // Find the *next* separator after first
               let firstSepIndex = menu.items.firstIndex(of: firstSeparator),
               let secondSepIndex = menu.items.firstIndex(of: secondSeparator),
               firstSepIndex < secondSepIndex else {
             print("Error: Could not find separators to update layout items.")
             return
         }

        for i in stride(from: secondSepIndex - 1, through: firstSepIndex + 1, by: -1) {
            if i < menu.items.count && menu.items[i].action == #selector(layoutMenuItemSelected(_:)) { // Be specific
                menu.removeItem(at: i)
            }
        }
        state.menuItemToSourceMap.removeAll()

        // --- Add Current Layout Items ---
        let insertIndex = firstSepIndex + 1 // Insert directly after the first separator
        for (index, source) in state.allSelectableSources.enumerated() {
            guard let name = getInputSourceLocalizedName(source), let id = getInputSourceID(source) else { continue }
            let menuItem = NSMenuItem(title: name, action: #selector(layoutMenuItemSelected(_:)), keyEquivalent: ""); menuItem.target = self
            menuItem.representedObject = source
            menuItem.state = (id == state.selectedSourceID1 || id == state.selectedSourceID2) ? .on : .off
            // Enablement logic: Allow deselection only when 2 are active, otherwise allow selection.
            menuItem.isEnabled = (state.availableSelectionCount == 2) ? (menuItem.state == .on) : true
            menu.insertItem(menuItem, at: insertIndex + index)
            state.menuItemToSourceMap[menuItem] = source
        }
    }

    /// Action called when a layout menu item is clicked. Handles selection/deselection and state updates.
    @objc func layoutMenuItemSelected(_ sender: NSMenuItem) {
        print("CapsLockSwitcher: Layout Item Selected: \(sender.title)")
        guard let represented = sender.representedObject else { return }
        let selectedSource = represented as! TISInputSource // Using force-cast based on previous error resolution
        guard let selectedID = getInputSourceID(selectedSource) else { return }

        let userDefaults = UserDefaults.standard; let wasSelected = sender.state == .on

        if wasSelected {
            // Deselect
            if state.selectedSourceID1 == selectedID { state.selectedSourceID1 = nil; userDefaults.removeObject(forKey: PrefKeys.selectedSourceID1) }
            else if state.selectedSourceID2 == selectedID { state.selectedSourceID2 = nil; userDefaults.removeObject(forKey: PrefKeys.selectedSourceID2) }
        } else {
            // Select (with overwrite logic for unavailable slots)
            let isSlot1EffectivelyEmpty = (state.selectedSourceID1 == nil || state.targetSource1Ref == nil)
            let isSlot2EffectivelyEmpty = (state.selectedSourceID2 == nil || state.targetSource2Ref == nil)
            if isSlot1EffectivelyEmpty { state.selectedSourceID1 = selectedID; userDefaults.set(selectedID, forKey: PrefKeys.selectedSourceID1) }
            else if isSlot2EffectivelyEmpty { state.selectedSourceID2 = selectedID; userDefaults.set(selectedID, forKey: PrefKeys.selectedSourceID2) }
            else { NSSound.beep(); return } // Both slots filled with valid items
        }
        userDefaults.synchronize()

        // Refresh state AFTER modifying selections
        fetchAllSelectableSources()
        updateActiveTargetRefsAndAvailabilityCount() // Recalculates count & updates internal tap flag
        updateMenuState() // Updates menu visuals (checkmarks, status, ICON)
        print("CapsLockSwitcher: UserDefaults updated - ID1: \(state.selectedSourceID1 ?? "nil"), ID2: \(state.selectedSourceID2 ?? "nil")")
    }


    // MARK: - Event Tap Logic

    /// Sets up the CGEventTap if permissions are granted.
    private func setupEventTap() {
        guard state.eventTap == nil else { print("CapsLockSwitcher: Event tap already exists."); return }
        // Double-check permissions just before creating
        guard checkAccessibilityPermissions(promptUserIfNeeded: false) else {
            print("Error: Cannot setup event tap, permissions not granted.")
            state.currentOperationalState = .permissionsRequired // Ensure state reflects reality
            updateStatusIcon(for: .permissionsRequired)
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: eventMask, callback: eventTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // Handle tap creation failure (might happen even if checkAccessibilityPermissions returned true initially)
            print("Error: Failed to create event tap."); state.currentOperationalState = .permissionsRequired
            updateStatusIcon(for: .permissionsRequired);
            // Show alert again to guide user
            DispatchQueue.main.async { self.showAccessibilityInstructionsAlert(triggeredByUserAction: false) }
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        state.eventTap = tap; state.runLoopSource = runLoopSource

        // Enable the tap at the system level. It stays enabled unless destroyed.
        CGEvent.tapEnable(tap: tap, enable: true)

        print("CapsLockSwitcher: Event tap created and enabled at system level.")
        updateTapEnabledState() // Set initial internal logic state based on current selections
    }

    /// Disables and removes the event tap.
    private func destroyEventTap() {
        guard let tap = state.eventTap, let source = state.runLoopSource else { return } // Ensure tap exists
        print("CapsLockSwitcher: Destroying event tap.")
        // Disable the tap at system level
        CGEvent.tapEnable(tap: tap, enable: false)
        // Remove the run loop source
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        // Nil out references
        state.eventTap = nil; state.runLoopSource = nil; state.isTapEnabled = false
    }

    /// Updates the internal Swift flag indicating if switching logic should be active.
    private func updateTapEnabledState() {
        let shouldBeLogicallyEnabled = (state.availableSelectionCount == 2)
        if shouldBeLogicallyEnabled != state.isTapEnabled {
            state.isTapEnabled = shouldBeLogicallyEnabled
            print("CapsLockSwitcher: Set internal tap logic enabled state to: \(state.isTapEnabled)")
        }
    }

    /// Instance method called by the C callback to handle the tapped event.
    /// Decides action based on permissions and internal state (`isTapEnabled`, `currentOperationalState`).
    func handleEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // --- Check permissions FIRST - crucial fix for revocation freeze ---
        guard checkAccessibilityPermissions(promptUserIfNeeded: false) else {
            // --- PERMISSIONS ARE LOST ---
            print("handleEventTap: Detected permission loss at start of callback.")

            // Check if *this specific event* is Caps Lock
            if type == .flagsChanged || type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == capsLockKeyCode {
                    print("handleEventTap: Caps Lock pressed while permissions are missing.")
                    // Show permissions alert, but only if not already showing/queued
                    if !state.isShowingPermissionAlert {
                        state.isShowingPermissionAlert = true // Set flag immediately
                         print("handleEventTap: Queueing permissions alert.")
                        DispatchQueue.main.async {
                            // Ensure tap hasn't been destroyed by another thread/check in the meantime
                            // (Though unlikely given main thread dispatch)
                            self.showAccessibilityInstructionsAlert(triggeredByUserAction: false)
                            // Reset flag after alert is dismissed
                            print("handleEventTap: Permissions alert dismissed. Resetting flag.")
                            self.state.isShowingPermissionAlert = false
                        }
                    } else { print("handleEventTap: Permissions alert already queued/showing. Ignoring Caps Lock.") }
                    // Consume the Caps Lock event - its "handling" is the alert/ignore.
                    // Asynchronous cleanup is triggered below anyway.
                    // return nil <--- Removed this consume here, let cleanup handle tap state first

                } // end if caps lock
            } // end if keydown/flagschanged

            // Regardless of event type, trigger asynchronous cleanup because permissions failed
            // Use weak self to avoid potential retain cycles
            DispatchQueue.main.async { [weak self] in
                self?.handleSuspectedPermissionLoss()
            }

            // --- Pass the event through ---
            // We detected loss, triggered cleanup, but shouldn't block the event now.
            // The cleanup will destroy the tap soon. Let system handle this event.
            return Unmanaged.passRetained(event)
        } // end guard checkAccessibilityPermissions


        // --- PERMISSIONS ARE OK ---
        if type == .flagsChanged || type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == capsLockKeyCode {
                // --- Handle Caps Lock when Permissions ARE Granted ---
                if state.isTapEnabled { // Active State (Count == 2)
                    if type == .flagsChanged { guard event.flags.contains(.maskAlphaShift) else { return Unmanaged.passRetained(event) } }

                    // Attempt TIS operations, check for failures (could indicate transient issues)
                    guard let currentSourceUnmanaged = TISCopyCurrentKeyboardInputSource() else {
                        print("Error: TISCopyCurrentKeyboardInputSource failed even with permissions.");
                        // Don't trigger full permission loss handling unless sure
                        // Maybe just log and pass through? Or attempt recovery? For now, pass.
                        return Unmanaged.passRetained(event)
                    }
                    let currentSource = currentSourceUnmanaged.takeRetainedValue()
                    guard let source1 = state.targetSource1Ref, let source2 = state.targetSource2Ref, let currentSourceID = getInputSourceID(currentSource) else {
                        print("Error: Missing internal state data during switch."); return Unmanaged.passRetained(event)
                    }
                    let targetSource = (currentSourceID == state.selectedSourceID1) ? source2 : source1
                    // print("CapsLockSwitcher: Attempting switch...") // Less verbose logging
                    let status = TISSelectInputSource(targetSource)
                    if status == noErr { /* print("CapsLockSwitcher: Switched."); */ return nil /* Consume */ }
                    else {
                        print("Error: TISSelectInputSource failed (\(status)) even with permissions.");
                        // Maybe log, don't assume permission loss immediately. Pass through.
                        return Unmanaged.passRetained(event)
                    }
                } else { // Inactive State (Configuring)
                    if state.currentOperationalState == .configuring {
                        if !state.isShowingConfigurationAlert {
                            state.isShowingConfigurationAlert = true; print("CapsLockSwitcher: Caps Lock pressed while configuring - Queueing alert.")
                            DispatchQueue.main.async { self.showConfigurationNeededAlert(); self.state.isShowingConfigurationAlert = false }
                        } else { print("CapsLockSwitcher: Config alert already queued/showing.") }
                        return nil // Consume event when showing/queueing config alert
                    } else { // Other inactive state (e.g., permissions required but guard passed somehow?)
                        print("CapsLockSwitcher: Caps Lock pressed while tap logic inactive but not configuring (\(state.currentOperationalState)). Passing."); return Unmanaged.passRetained(event)
                    }
                } // end if state.isTapEnabled else
            } // end if caps lock
        } // end if keydown/flagschanged

        return Unmanaged.passRetained(event) // Pass non-caps lock events or unhandled caps lock
    }


    // MARK: - Helper Functions
    /// Manages the system-level CapsLockDelayOverride using hidutil.
    /// - Parameter setOverride: If true, sets the delay override to 0. If false, attempts to reset the override
    private func manageCapsLockDelayOverride(setOverride: Bool) {
        // Use "0" to set the override, "200" to reset it to default.
        let propertyValue = setOverride ? "0" : "200"
        let jsonString = "{\"CapsLockDelayOverride\":\(propertyValue)}"
        let actionDescription = setOverride ? "set CapsLockDelayOverride to 0" : "reset CapsLockDelayOverride"

        print("CapsLockSwitcher: Attempting to \(actionDescription)...")

        let process = Process()
        // Ensure the path to hidutil is correct. /usr/bin/ is standard.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", jsonString]

        // Optional: Capture output/errors for debugging
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit() // Wait for the command to complete

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 // Log output only if it's not empty to avoid noise
                 print("hidutil output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            if process.terminationStatus == 0 {
                print("CapsLockSwitcher: Successfully \(actionDescription).")
            } else {
                // Log a warning if the command finished with an error status
                print("Warning: hidutil command finished with status \(process.terminationStatus). \(actionDescription) might have failed.")
            }
        } catch {
            // Log an error if process.run() itself throws (e.g., command not found)
            print("Error executing hidutil to \(actionDescription): \(error.localizedDescription)")
        }
    }
    
    /// Handles cleanup and UI update when permission loss is detected, run on main thread.
    private func handleSuspectedPermissionLoss() {
        // Ensure we are on the main thread for UI updates and state changes
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleSuspectedPermissionLoss() }; return
        }
        print("handleSuspectedPermissionLoss: Running on main thread.")

        // Double-check permissions now that we are on the main thread
        guard !checkAccessibilityPermissions(promptUserIfNeeded: false) else {
            print("handleSuspectedPermissionLoss: Permissions seem to be granted again? No action taken."); return
        }

        print("handleSuspectedPermissionLoss: Confirmed loss. Destroying tap & updating UI.")
        // Destroy the tap if it still exists
        if state.eventTap != nil {
            destroyEventTap() // This function handles nilling out state vars and disabling tap
        }
        // Ensure UI reflects the required state
        if state.currentOperationalState != .permissionsRequired {
            print("handleSuspectedPermissionLoss: Updating state and UI to Permissions Required.")
            state.currentOperationalState = .permissionsRequired
            setupStatusBar() // Rebuild limited menu & icon
        } else {
            // Already in correct state, maybe just ensure icon is right
            print("handleSuspectedPermissionLoss: State already Permissions Required. Ensuring icon.")
            updateStatusIcon(for: .permissionsRequired)
        }
    }

    /// Shows the alert instructing user to select layouts.
    private func showConfigurationNeededAlert() {
         guard !(NSApp.modalWindow?.isVisible ?? false) else { // Prevent multiple modals
             print("Configuration Needed Alert: Already presenting another modal.")
             return
         }
        let alert = NSAlert(); alert.messageText = "Configure Layouts"
        alert.informativeText = "Please select two keyboard layouts from the \(Bundle.main.appName) menu bar icon to enable Caps Lock switching."
        alert.alertStyle = .informational;
        print("CapsLockSwitcher: Displaying configuration needed alert.")
        alert.runModal() // Blocks main thread until dismissed
        print("Configuration Needed Alert: Alert dismissed.")
    }

    /// Safely retrieves the Input Source ID (e.g., "com.apple.keylayout.US").
    private func getInputSourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Safely retrieves the localized Input Source Name (e.g., "U.S.").
    private func getInputSourceLocalizedName(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Convenience function to terminate the app, potentially useful in error conditions.
    private func terminateApp() {
        print("CapsLockSwitcher: Terminating due to critical error."); destroyEventTap(); NSApplication.shared.terminate(self)
    }
}

// Helper extension for Bundle name
extension Bundle {
    var appName: String { return object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CapsLockSwitcher" }
}
