import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 启动后自动扫描一次当前网段
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak controller] in
            controller?.rescan(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 LANScanner", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "扫描设置…", action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 LANScanner", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "退出 LANScanner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let scanItem = NSMenuItem()
        let scanMenu = NSMenu(title: "扫描")
        scanMenu.addItem(NSMenuItem(title: "重新扫描局域网", action: #selector(MainWindowController.rescan(_:)), keyEquivalent: "r"))
        scanMenu.addItem(NSMenuItem(title: "扫描选中设备的端口", action: #selector(MainWindowController.scanSelectedPorts(_:)), keyEquivalent: "p"))
        scanMenu.addItem(NSMenuItem(title: "将选中设备加入唤醒列表", action: #selector(MainWindowController.addSelectedToWOL(_:)), keyEquivalent: "l"))
        scanMenu.addItem(.separator())
        scanMenu.addItem(NSMenuItem(title: "网络唤醒设备列表", action: #selector(MainWindowController.showWOL(_:)), keyEquivalent: "2"))
        scanMenu.addItem(.separator())
        scanMenu.addItem(NSMenuItem(title: "显示所有主机", action: #selector(MainWindowController.showAllHosts(_:)), keyEquivalent: "1"))
        scanItem.submenu = scanMenu
        mainMenu.addItem(scanItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }
}
