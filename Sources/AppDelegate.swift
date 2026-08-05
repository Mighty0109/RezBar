import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuController: MenuController?

    /// Explicit entry point.
    ///
    /// The `main()` that AppKit supplies for `@main` on an `NSApplicationDelegate` goes through
    /// `NSApplicationMain`, which only ever assigns a delegate by loading it from a MainMenu nib.
    /// RezBar ships no storyboard and no nib, so that path leaves `NSApp.delegate` nil:
    /// `applicationDidFinishLaunching` never fires, no status item is created, and the app sits
    /// in its run loop with nothing in the menu bar. Wiring the delegate up by hand is what makes
    /// a nib-less AppKit app actually start.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no app switcher entry.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MenuController()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
