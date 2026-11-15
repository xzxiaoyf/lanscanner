import AppKit
import Foundation
import Darwin

// 版本自查：不启动 GUI，用于确认双击运行的 .app 是否为最新构建
// 用法：LANScanner.app/Contents/MacOS/LANScanner --version
if CommandLine.arguments.contains("--version") {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.3"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1.1.3"
    let execPath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    let attrs = try? FileManager.default.attributesOfItem(atPath: execPath)
    var built = "未知"
    if let date = attrs?[.modificationDate] as? Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        built = formatter.string(from: date)
    }
    print("LANScanner \(short) (构建 \(build))")
    #if arch(arm64)
    print("当前运行架构: arm64 (Apple Silicon)")
    #else
    print("当前运行架构: x86_64 (Intel)")
    #endif
    print("系统版本: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("架构: x86_64 + arm64 (Universal)")
    print("功能: 局域网设备发现 / 端口扫描 / OUI 厂商与设备名 / 网络选择 / WOL 网络唤醒")
    print("可执行文件: \(execPath)")
    print("构建时间: \(built)")
    print("OUI 数据库: \(OUIVendor.sourceDescription)")
    let kernel = ARPCache.readKernelARP()
    print("ARP 内核通道: \(kernel.messages) 条路由消息 / \(kernel.entries.count) 条含 MAC" +
          "（消息头 \(kernel.headerUsed) 字节，errno=\(kernel.errno)）")
    print("排查 MAC / 厂商缺失: \(CommandLine.arguments[0]) --arpdiag")
    exit(0)
}

// 跨机器 ARP 诊断：不启动 GUI，输出每个数据来源的原始输出与解析结果
// 用法：LANScanner.app/Contents/MacOS/LANScanner --arpdiag
if CommandLine.arguments.contains("--arpdiag") {
    ARPDiagnostics.run()
    exit(0)
}

// 命令行自检：不启动 GUI，直接验证网段发现、ARP 解析与端口扫描
// 用法：LANScanner --selftest
if CommandLine.arguments.contains("--selftest") {
    CLISelfTest.start()
    dispatchMain()
}

// 离屏渲染界面为 PDF，用于无屏幕权限环境下核对布局
// 用法：LANScanner --uirender /tmp/ui.pdf [ports|picker|settings|wol]
if let index = CommandLine.arguments.firstIndex(of: "--uirender"),
   CommandLine.arguments.count > index + 1 {
    let path = CommandLine.arguments[index + 1]
    let mode = CommandLine.arguments.dropFirst(index + 2).first ?? ""
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.appearance = NSAppearance(named: .darkAqua)

    if mode == "picker" {
        let picker = NetworkPickerController(networks: LocalNetwork.all())
        picker.showWindow(nil)
        guard let root = picker.window?.contentView else { exit(1) }
        root.layoutSubtreeIfNeeded()
        let pdf = root.dataWithPDF(inside: root.bounds)
        try? pdf.write(to: URL(fileURLWithPath: path))
        print("已生成网络选择面板预览: \(path)")
        exit(0)
    }
    if mode == "settings" {
        let controller = PreferencesViewController()
        _ = controller.view
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 344, height: 580)
        root.layoutSubtreeIfNeeded()
        let pdf = root.dataWithPDF(inside: root.bounds)
        try? pdf.write(to: URL(fileURLWithPath: path))
        print("已生成扫描设置预览: \(path)")
        exit(0)
    }

    if mode == "wol" {
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.loadWOLPreview()
        guard let root = controller.window?.contentView else { exit(1) }
        root.layoutSubtreeIfNeeded()
        let pdf = root.dataWithPDF(inside: root.bounds)
        try? pdf.write(to: URL(fileURLWithPath: path))
        print("已生成网络唤醒界面预览: \(path)")
        exit(0)
    }

    let showPorts = mode == "ports"
    let controller = MainWindowController()
    controller.showWindow(nil)
    controller.loadPreview(showPorts: showPorts)
    guard let root = controller.window?.contentView else { exit(1) }
    root.layoutSubtreeIfNeeded()
    let pdf = root.dataWithPDF(inside: root.bounds)
    try? pdf.write(to: URL(fileURLWithPath: path))
    print("已生成界面预览: \(path)")
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.appearance = NSAppearance(named: .darkAqua)
application.run()
