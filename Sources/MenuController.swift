import AppKit
import CoreGraphics
import ServiceManagement

/// Payload attached to a mode menu item, so the action knows what to apply and where.
private final class ModeAction: NSObject {
    let displayID: CGDirectDisplayID
    let mode: ModeInfo

    init(displayID: CGDirectDisplayID, mode: ModeInfo) {
        self.displayID = displayID
        self.mode = mode
    }
}

/// Owns the status bar item and rebuilds the menu from scratch every time it opens.
///
/// Rebuilding on open (rather than caching) is the whole point of this design: displays get
/// hot-plugged and resolutions get changed from System Settings or other tools, and a cached menu
/// would silently show stale entries and stale checkmarks.
final class MenuController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "display", accessibilityDescription: "RezBar")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "RezBar"
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: - Menu construction

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        switch ModeLogic.plan(for: DisplayManager.snapshot()) {
        case .empty:
            let item = NSMenuItem(title: "No displays found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

        case .topLevel(let plan):
            appendGroups(plan, to: menu)

        case .submenus(let plans):
            for plan in plans {
                let header = NSMenuItem(title: plan.display.name, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                appendGroups(plan, to: submenu)
                header.submenu = submenu
                menu.addItem(header)
            }
        }

        menu.addItem(.separator())
        menu.addItem(makeLoginItem())

        let quit = NSMenuItem(title: "Quit RezBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func appendGroups(_ plan: DisplayPlan, to menu: NSMenu) {
        guard !plan.groups.isEmpty else {
            let item = NSMenuItem(title: "No modes available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let current = plan.display.current

        for group in plan.groups {
            let item = NSMenuItem(title: group.label, action: nil, keyEquivalent: "")
            // The checkmark tracks the group, so it stays visible whether or not the exact
            // refresh rate lives behind a submenu.
            item.state = (current.map(group.contains) ?? false) ? .on : .off

            if group.needsRateSubmenu {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for mode in group.modes {
                    let rateItem = NSMenuItem(
                        title: ModeLogic.formatRate(mode.refreshRate),
                        action: #selector(selectMode(_:)),
                        keyEquivalent: ""
                    )
                    rateItem.target = self
                    rateItem.representedObject = ModeAction(displayID: plan.display.id, mode: mode)
                    rateItem.state = (mode == current) ? .on : .off
                    submenu.addItem(rateItem)
                }
                item.submenu = submenu
            } else if let only = group.modes.first {
                // Exactly one rate: no submenu, switch directly.
                item.action = #selector(selectMode(_:))
                item.target = self
                item.representedObject = ModeAction(displayID: plan.display.id, mode: only)
            }

            menu.addItem(item)
        }
    }

    private func makeLoginItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status

        if status == .requiresApproval {
            let item = NSMenuItem(
                title: "Start at Login (Requires Approval)",
                action: #selector(openLoginItemsSettings),
                keyEquivalent: ""
            )
            item.target = self
            item.state = .off
            return item
        }

        let item = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        item.target = self
        item.state = (status == .enabled) ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ModeAction else { return }

        let result = DisplayManager.apply(action.mode, to: action.displayID)
        guard result != .success else { return }

        present(
            title: "Could Not Change Resolution",
            message: DisplayManager.message(for: result)
        )
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            present(
                title: "Could Not Update Login Item",
                message: "\(error.localizedDescription)\n\nLogin items only work reliably once RezBar has been moved to your Applications folder."
            )
        }
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    /// An accessory (menu bar only) app is not frontmost, so it must activate itself or the alert
    /// appears behind whatever the user was doing.
    private func present(title: String, message: String) {
        NSApp.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
