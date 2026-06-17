import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Keep the app running in the background when the window is closed/hidden.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Re-show the window when the Dock icon is clicked.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    for window in sender.windows {
      window.makeKeyAndOrderFront(self)
    }
    NSApp.activate(ignoringOtherApps: true)
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
