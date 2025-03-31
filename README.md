# CapsLockSwitcher for macOS

[![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)](https://www.apple.com/macos)
[![License](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE.md)

**CapsLockSwitcher** is a lightweight macOS background agent that provides **instant, reliable switching between exactly two user-selected keyboard input sources (layouts) using the Caps Lock key**.

It's designed to overcome the common frustrations with the native macOS input switching behavior.

## Why CapsLockSwitcher?

Are you tired of:

1.  **The noticeable delay** (hundreds of milliseconds) when switching input sources using the standard macOS methods?
2.  The native "Use Caps Lock to switch..." setting **cycling through *all* your enabled layouts**, including the often unwanted "ABC" or U.S. layout, instead of just the two you frequently use?
3.  Accidentally activating the **actual Caps Lock state** (uppercase typing) when you just wanted to switch layouts?

CapsLockSwitcher solves these problems by providing a dedicated, fast, and targeted switching mechanism.

## Features

*   🚀 **Instant Switching:** Bypasses the standard macOS input source switching delay by using lower-level APIs.
*   🎯 **User-Selectable Layouts:** Switches *only* between the two keyboard layouts you explicitly choose in its menu.
*   🚫 **No Accidental Caps Lock:** Consumes the Caps Lock key press when switching, preventing the standard uppercase lock from activating. If the app isn't configured or loses permissions, the event is passed through, restoring default OS behavior.
*   💡 **Lightweight & Native:** Runs as a background agent with no Dock icon. Uses standard macOS APIs (`CGEventTap`, Text Input Source Services) – no kernel extensions needed.
*   ⚙️ **Simple Configuration:** All setup is done via a status bar menu item (looks like ⌨️). Clearly guides you through granting the necessary Accessibility permissions required for event monitoring.
*   🚦 **Status Bar Icon:** The status bar icon changes to indicate its state (Active, Configuring, Permissions Required).
*   🚀 **Launch on Startup:** Optional setting to automatically start the app when you log in (macOS 13+ required).
*   🔒 **Secure:** Requires Accessibility permissions (standard for input monitoring tools) but minimizes attack surface compared to more complex solutions. The permission requirement is clearly explained.
*   🐛 **Robust Error Handling:**  Gracefully handles permission revocation and layout availability changes to prevent input freezes.

## Installation

### Recommended

1.  Go to the [**Releases**](https://github.com/doasync/CapsLockSwitcher/releases) page of this repository. 
2.  Download the latest `.app` file.
3.  Copy `CapsLockSwitcher.app` to your `/Applications` folder.
4.  Launch `CapsLockSwitcher` from your Applications folder.
5.  Run `xattr -cr /Applications/CapsLockSwitcher.app` in the terminal

`xattr -cr /Applications/CapsLockSwitcher.app` removes extended attributes recursively (`-r`) and clears code signing attributes (`-c`) from the `CapsLockSwitcher.app` application. It's essentially stripping away the "downloaded from the internet" flags that macOS Gatekeeper uses to restrict the app's execution.

## Usage

1.  **Launch the App:** Double-click `CapsLockSwitcher` in your Applications folder. A new icon (⚠️ or ⌨️...) will appear in your menu bar.
2.  **Grant Permissions:**
    *   The app *requires* **Accessibility** permissions to monitor the Caps Lock key.
    *   If permissions are needed, the icon will be ⚠️. Click it and select "Show Permissions Guide" or follow the automatic prompt (if shown).
    *   This will open **System Settings > Privacy & Security > Accessibility**.
    *   Find `CapsLockSwitcher` in the list and enable the toggle next to it. If it's not listed, drag `CapsLockSwitcher.app` from your Applications folder into the list or use the '+' button.
    *   *Note:* You might need to unlock the settings panel with your password.
3.  **Configure Layouts:**
    *   Once permissions are granted, the icon should change to ⌨️....
    *   Click the status bar icon.
    *   You will see a list of your currently enabled keyboard layouts.
    *   Click on the **first** layout you want to switch between. A checkmark will appear next to it. The status text will update (e.g., "Select 1 more layout...").
    *   Click on the **second** layout you want to switch between. Another checkmark will appear.
4.  **Activate Switching:**
    *   Once two layouts are selected, the status bar icon will change to ⌨️ (`keyboard.fill`), and the status text will show "Switcher: Active".
    *   **Press the Caps Lock key!** It will now instantly switch between the two layouts you selected.
5.  **(Optional) Launch on Startup:**
    *   Click the status bar icon.
    *   Select "Launch on Startup" to toggle the setting (requires macOS 13+). A checkmark indicates it's enabled.

## Permissions Explained

CapsLockSwitcher needs **Accessibility** permissions for one specific reason:

*   **To Monitor CapsLock Key:** It uses a `CGEventTap` to listen for keyboard events system-wide, specifically looking for the Caps Lock key press (`keyDown` and `flagsChanged` events). This is the standard macOS mechanism for this kind of functionality.

The app **does not** log your keystrokes or send any data anywhere. It only checks if the key pressed is Caps Lock and, if configured, consumes that event to trigger the layout switch. Granting Accessibility permission is necessary for *any* application that needs to modify or observe input events outside of its own window.

## Troubleshooting

*   **Not Switching:**
    *   **Check Permissions:** Click the icon. If it's ⚠️ or the "Show Permissions Guide" item is present, re-verify permissions in System Settings > Privacy & Security > Accessibility. Try toggling the permission off and on again.
    *   **Check Selection:** Click the icon. Ensure exactly two layouts have checkmarks next to them. Make sure the layouts you selected are still *enabled* in System Settings > Keyboard > Input Sources.
    *   **Restart the App:** Quit CapsLockSwitcher (via its menu) and relaunch it.
*   **Input Freezes (Fixed):** The app includes safeguards against this, but if your system input freezes *after* installing/running the app (especially after changing permissions), try forcefully restarting the app or toggling Accessibility permissions. If it persists, please report an issue.
*   **Layout Not Listed in Menu:** Ensure the desired keyboard layout is added and enabled in macOS **System Settings > Keyboard > Text Input > Input Sources** (Edit...). Only enabled, selectable keyboard layouts appear in the CapsLockSwitcher menu.
*   **"Launch on Startup" Fails:** This feature requires macOS 13 or later. If you encounter errors enabling it, ensure you are on a compatible OS version. An alert might provide more details if the system rejects the request.

## Building from Source

1.  Clone this repository: `git clone https://github.com/doasync/CapsLockSwitcher.git`
2.  Open `CapsLockSwitcher.xcodeproj` in Xcode (ensure you have a recent version compatible with Swift and macOS 13+ features like `SMAppService`).
3.  Select the `CapsLockSwitcher` target and your Mac as the run destination.
4.  Build the project (Product > Build or Cmd+B). The resulting `.app` bundle will be in the Products directory.

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs, feature requests, or suggestions.

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.
