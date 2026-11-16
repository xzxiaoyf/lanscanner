import AppKit
import Foundation

/// 版本信息：让用户可直接确认当前运行的是哪一次构建
enum AppVersionInfo {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.4"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1.1.4"
    }
    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }
    static var builtAt: String {
        guard let date = try? FileManager.default.attributesOfItem(atPath: executablePath)[.modificationDate] as? Date else {
            return "未知"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    static var arpText: String {
        if let snapshot = ARPCache.lastSnapshot() {
            return "最近一次扫描：\(snapshot.entries.count) 条邻居记录 / \(snapshot.macCount) 条含 MAC" +
                   " · 内核路由表 \(snapshot.kernelCount) 条"
        }
        let kernel = ARPCache.readKernelARP()
        return "内核路由表 \(kernel.entries.count) 条含 MAC（errno=\(kernel.errno)）"
    }
    static var aboutText: String {
        """
        版本 \(short)（构建 \(build)）  ·  Universal (x86_64 + arm64)
        构建时间：\(builtAt)

        功能：局域网设备发现、端口扫描、OUI 厂商与设备名识别、
        多网络选择、WOL 网络唤醒（Magic Packet）。

        OUI 数据库：\(OUIVendor.sourceDescription)
        （完整前缀库已内嵌，外部 oui.txt 缺失时仍可识别厂商）

        MAC 来源：内核路由表 / arp / netstat 多通道兜底
        \(arpText)
        （命令行 --arpdiag 可导出跨机器诊断信息）

        可执行文件：\(executablePath)
        """
    }
}

// MARK: - 窗口与主状态

final class MainWindowController: NSWindowController {

    private var network: LocalNetwork?
    private var hosts: [Host] = []
    private var portScans: [String: PortScanOutcome] = [:]
    private var scannedHosts: Set<String> = []
    private var lanScanner: LANScanner?
    private var portScanner: PortScanner?
    private var networkPicker: NetworkPickerController?

    private var filter: HostFilter = .all
    private var sortKey: SortKey = .ip
    private var searchText: String = ""
    private var selectedIP: String?
    private var portScanningIP: String?

    private let titleBar = TitleBarView()
    private let rail = RailView()
    private let listVC = HostListViewController()
    private let detailVC = DetailViewController()
    private let wolVC = WOLViewController()
    private var rootView: RootView?
    private var showingWOL = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "LANScanner"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.window
        window.minSize = NSSize(width: 940, height: 620)
        window.center()
        window.toolbar = nil
        super.init(window: window)

        let root = RootView()
        root.titleBar = titleBar
        root.rail = rail
        root.listView = listVC.view
        root.detailView = detailVC.view
        root.wolView = wolVC.view
        root.wolMode = false
        window.contentView = root
        rootView = root

        wireCallbacks()
        listVC.update(hosts: [], selectedIP: nil, status: "尚未扫描")
        detailVC.showEmpty()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func wireCallbacks() {
        titleBar.onScan = { [weak self] in
            guard let self else { return }
            if ScanSettings.shared.showNetworkPicker {
                self.presentNetworkPicker()
            } else {
                self.rescan(nil)
            }
        }
        titleBar.onSettings = { [weak self] in self?.showSettings(nil) }
        titleBar.onSearch = { [weak self] text in
            self?.searchText = text
            self?.wolVC.setSearch(text)
            self?.pushList()
        }
        titleBar.onInfo = {
            let alert = NSAlert()
            alert.messageText = "LANScanner \(AppVersionInfo.short)"
            alert.informativeText = AppVersionInfo.aboutText
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        titleBar.onWOL = { [weak self] in self?.showWOLMode() }
        titleBar.onRefresh = { [weak self] in self?.rescan(nil) }
        titleBar.onHistory = { [weak self] in
            self?.filter = .scanned
            self?.rail.select(index: HostFilter.scanned.rawValue)
            self?.showHostsMode()
        }

        rail.onSelect = { [weak self] index in
            guard let self else { return }
            if index == 4 {
                self.showWOLMode()
            } else {
                self.filter = HostFilter(rawValue: index) ?? .all
                self.showHostsMode()
            }
        }

        listVC.onSortChanged = { [weak self] key in
            self?.sortKey = key
            self?.pushList()
        }
        listVC.onSelect = { [weak self] host in self?.select(host) }
        listVC.onScanPorts = { [weak self] host in self?.startPortScan(for: host) }
        listVC.onAddToWOL = { [weak self] host in self?.addToWOL(host) }

        detailVC.onScanPorts = { [weak self] host in self?.startPortScan(for: host) }
        detailVC.onCancelPorts = { [weak self] in self?.cancelPortScan() }
        detailVC.onNoteChanged = { [weak self] ip, note in
            guard let self else { return }
            if let index = self.hosts.firstIndex(where: { $0.ip == ip }) {
                self.hosts[index].note = note
            }
            self.pushList()
        }
        detailVC.onConnect = { [weak self] host in self?.connect(to: host) }
        detailVC.onWOLAction = { [weak self] host in self?.wolAction(for: host) }

        wolVC.onAddScannedSelection = { [weak self] in self?.addSelectedToWOL(nil) }
        wolVC.onDevicesChanged = { [weak self] in self?.refreshWOLIndicators() }
    }

    // MARK: WOL 页面切换

    private func showWOLMode() {
        showingWOL = true
        rootView?.wolMode = true
        rail.select(index: 4)
        wolVC.reload()
        wolVC.setSearch(searchText)
    }

    private func showHostsMode() {
        showingWOL = false
        rootView?.wolMode = false
        pushList()
    }

    @objc func showWOL(_ sender: Any?) { showWOLMode() }

    private func refreshWOLIndicators() {
        pushList()
        if let ip = selectedIP, let host = hosts.first(where: { $0.ip == ip }) {
            detailVC.updateWOLState(for: host)
        }
    }

    private func addToWOL(_ host: Host) {
        guard host.mac != nil else {
            let alert = NSAlert()
            alert.messageText = "无法加入唤醒列表"
            alert.informativeText = "该设备没有 MAC 地址（ARP 缓存中未解析），请重新扫描后再试。"
            alert.runModal()
            return
        }
        let alreadyInList = WOLStore.shared.contains(mac: host.mac)
        wolVC.add(host: host)
        if alreadyInList {
            showWOLMode()
            listVC.setStatus("设备已在唤醒列表中：\(host.displayName)")
        } else {
            listVC.setStatus("已加入唤醒列表：\(host.displayName)  ·  \(host.mac ?? "")")
        }
        refreshWOLIndicators()
    }

    /// 详情面板的 WOL 按钮：未加入则加入，已加入则切到列表并立即唤醒
    private func wolAction(for host: Host) {
        if WOLStore.shared.contains(mac: host.mac) {
            showWOLMode()
            if let mac = host.mac { wolVC.wake(mac: mac) }
        } else {
            addToWOL(host)
        }
    }

    @objc func addSelectedToWOL(_ sender: Any?) {
        guard let ip = selectedIP, let host = hosts.first(where: { $0.ip == ip }) else {
            let alert = NSAlert()
            alert.messageText = "请先选择一台设备"
            alert.informativeText = "在主机列表中选中设备后，可点击行右侧的电源按钮，或使用本菜单加入唤醒列表。"
            alert.runModal()
            return
        }
        addToWOL(host)
    }

    // MARK: 数据筛选

    private var visibleHosts: [Host] {
        var list = hosts
        switch filter {
        case .all: break
        case .gateway: list = list.filter { $0.isGateway }
        case .reachable: list = list.filter { $0.isReachable }
        case .scanned: list = list.filter { scannedHosts.contains($0.ip) }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            list = list.filter {
                $0.ip.lowercased().contains(query) ||
                $0.vendor.lowercased().contains(query) ||
                ($0.hostname ?? "").lowercased().contains(query) ||
                ($0.mac ?? "").lowercased().contains(query) ||
                $0.note.lowercased().contains(query)
            }
        }
        switch sortKey {
        case .ip: list.sort { $0.ipValue < $1.ipValue }
        case .name: list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .vendor: list.sort {
            let a = $0.vendor, b = $1.vendor
            if a == b { return $0.ipValue < $1.ipValue }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        }
        return list
    }

    private func pushList() {
        let status: String
        if hosts.isEmpty {
            status = "尚未扫描"
        } else {
            status = "发现 \(hosts.count) 主机" + (visibleHosts.count != hosts.count ? " · 当前显示 \(visibleHosts.count)" : "")
        }
        listVC.update(hosts: visibleHosts, selectedIP: selectedIP, status: status)
    }

    private func select(_ host: Host) {
        selectedIP = host.ip
        detailVC.show(host: host,
                      outcome: portScans[host.ip],
                      scanning: portScanningIP == host.ip)
        listVC.update(hosts: visibleHosts, selectedIP: selectedIP, status: nil)
    }

    /// 用示例数据填充界面，供 --uirender 预览及无网络环境下检查布局
    func loadPreview(showPorts: Bool) {
        let samples: [(String, String, String, String?, Bool, Double?)] = [
            ("192.168.31.1", "50:92:6A:28:7A:4C", "Beijing Xiaomi Mobile Software Co., Ltd", "xiaoqiang", true, 3.3),
            ("192.168.31.21", "7C:C2:94:0A:A9:A7", "Beijing Xiaomi Mobile Software Co., Ltd", "lumi-curtain-hmcn01", false, 128.6),
            ("192.168.31.27", "8A:36:A4:18:CB:0B", "私人 MAC 地址", "ipad", false, 108.6),
            ("192.168.31.33", "E4:AA:EC:60:35:D3", "Tianjin Hualai Technology Co., Ltd", nil, false, 3.7),
            ("192.168.31.38", "70:70:FC:04:F4:7D", "GOLD&WATER INDUSTRIAL LIMITED", "miwifi-ra69-omv", false, 1.7),
            ("192.168.31.51", "54:48:E6:51:99:8C", "Beijing Xiaomi Mobile Software Co., Ltd", "chuangmi-plug-212a01", false, 84.1),
            ("192.168.31.70", "3C:C5:DD:B7:49:71", "Hui Zhou Gaoshengda Technology Co., Ltd", nil, false, nil),
            ("192.168.31.107", "04:CF:8C:18:97:6A", "XIAOMI Electronics,CO.,LTD", nil, false, 107.9),
            ("192.168.31.116", "B4:60:ED:25:43:AA", "Beijing Xiaomi Mobile Software Co., Ltd", nil, false, 279.8),
            ("192.168.31.184", "E4:FE:43:41:3F:0E", "Beijing Xiaomi Mobile Software Co., Ltd", nil, false, 376.0)
        ]
        hosts = samples.map { ip, mac, vendor, hostname, gateway, rtt in
            Host(ip: ip, mac: mac, vendor: vendor, hostname: hostname, rttMs: rtt,
                 isGateway: gateway, isReachable: rtt != nil,
                 fromARPOnly: rtt == nil, note: "")
        }
        selectedIP = hosts.first?.ip
        if showPorts, let ip = selectedIP {
            let results = [53, 80, 443, 8080].map { port in
                PortResult(port: port, service: ServiceNames.name(for: port),
                           banner: "", responseMs: 3.2)
            }
            portScans[ip] = PortScanOutcome(results: results, scanned: 78, elapsed: 0.95)
            scannedHosts.insert(ip)
        }
        titleBar.setScanning(false, text: "扫描")
        pushList()
        if let first = hosts.first { select(first) }
        if showPorts { detailVC.selectTab(.ports) }
    }

    /// 供 --uirender 预览 WOL 页面，示例数据不写入真实存储
    func loadWOLPreview() {
        loadPreview(showPorts: false)
        var samples = [
            WOLDevice.make(mac: "50:92:6A:28:7A:4C", ip: "192.168.31.1",
                           name: "小米路由器", vendor: "Beijing Xiaomi Mobile Software Co., Ltd"),
            WOLDevice.make(mac: "00:11:32:8A:9B:10", ip: "192.168.31.38",
                           name: "书房 NAS", vendor: "Synology Incorporated"),
            WOLDevice.make(mac: "3C:52:82:11:22:33", ip: "192.168.31.116",
                           name: "客厅台式机", vendor: "Hewlett Packard")
        ]
        samples[0].wakeCount = 12
        samples[0].lastWokenAt = Date().addingTimeInterval(-3600)
        samples[1].wakeCount = 3
        samples[1].lastWokenAt = Date().addingTimeInterval(-86400)
        samples[1].broadcast = "192.168.31.255"
        wolVC.setPreview(samples)
        showWOLMode()
    }

    // MARK: 局域网扫描

    @objc func rescan(_ sender: Any?) {
        guard let network = LocalNetwork.current() else {
            let alert = NSAlert()
            alert.messageText = "无法识别局域网"
            alert.informativeText = "未找到已启用且具有 IPv4 地址的网络接口。请检查网络连接后重试。"
            alert.runModal()
            return
        }
        startScan(with: network)
    }

    /// 弹出网络选择面板，让用户挑选接口或手动指定 IP 范围
    private func presentNetworkPicker() {
        let networks = LocalNetwork.all()
        guard !networks.isEmpty else {
            rescan(nil)
            return
        }
        let picker = NetworkPickerController(networks: networks)
        picker.onScan = { [weak self] network in
            self?.networkPicker = nil
            self?.startScan(with: network)
        }
        picker.onCancel = { [weak self] in self?.networkPicker = nil }
        networkPicker = picker
        picker.showWindow(nil)
        picker.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startScan(with network: LocalNetwork) {
        lanScanner?.cancel()
        self.network = network
        let label = network.scanLabel
        titleBar.setScanning(true, text: "正在扫描 \(label)")
        listVC.update(hosts: visibleHosts, selectedIP: selectedIP,
                      status: "正在扫描 \(label) · 0/\(network.hostIPs.count)")

        let scanner = LANScanner()
        lanScanner = scanner
        scanner.scan(network: network, progress: { [weak self] done, total, _ in
            guard let self else { return }
            self.listVC.setStatus("正在扫描 \(label) · \(done)/\(total)")
        }, completion: { [weak self] found in
            guard let self else { return }
            self.hosts = found
            self.titleBar.setScanning(false, text: "扫描")
            let preferred = self.selectedIP ?? network.gateway ?? found.first?.ip
            self.selectedIP = preferred
            self.pushList()
            if let ip = preferred, let host = found.first(where: { $0.ip == ip }) {
                self.select(host)
            } else {
                self.detailVC.showEmpty()
            }
        })
    }

    // MARK: 端口扫描

    @objc func scanSelectedPorts(_ sender: Any?) {
        guard let ip = selectedIP, let host = hosts.first(where: { $0.ip == ip }) else {
            let alert = NSAlert()
            alert.messageText = "请先选择一台设备"
            alert.informativeText = "在左侧列表中选中主机后，可点击行右侧的箭头或右侧的「扫描端口」按钮。"
            alert.runModal()
            return
        }
        startPortScan(for: host)
    }

    private func cancelPortScan() {
        portScanner?.cancel()
        portScanner = nil
        portScanningIP = nil
        if let ip = selectedIP, let host = hosts.first(where: { $0.ip == ip }) {
            detailVC.show(host: host, outcome: portScans[ip], scanning: false)
        }
        pushList()
    }

    private func startPortScan(for host: Host) {
        portScanner?.cancel()
        let ports = ScanSettings.shared.ports
        guard !ports.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "端口列表为空"
            alert.informativeText = "自定义端口格式无效，例如：80,443,8000-8100。请在扫描设置中修改。"
            alert.runModal()
            return
        }

        selectedIP = host.ip
        portScanningIP = host.ip
        pushList()
        detailVC.show(host: host, outcome: nil, scanning: true)
        detailVC.setPortProgress(0, total: ports.count)
        detailVC.selectTab(.ports)

        let scanner = PortScanner()
        portScanner = scanner
        scanner.scan(ip: host.ip, ports: ports,
                     timeoutMs: ScanSettings.shared.portTimeoutMs,
                     progress: { [weak self] done, total in
            guard let self, self.portScanningIP == host.ip else { return }
            self.detailVC.setPortProgress(done, total: total)
        }, completion: { [weak self] outcome in
            guard let self, self.portScanningIP == host.ip else { return }
            self.portScans[host.ip] = outcome
            self.scannedHosts.insert(host.ip)
            self.portScanningIP = nil
            self.portScanner = nil
            self.detailVC.show(host: host, outcome: outcome, scanning: false)
            self.pushList()
        })
    }

    // MARK: 其它动作

    @objc func showSettings(_ sender: Any?) {
        titleBar.presentSettings(apply: { [weak self] in
            self?.pushList()
        }, onPickNetwork: { [weak self] in
            self?.presentNetworkPicker()
        })
    }

    @objc func showAllHosts(_ sender: Any?) {
        filter = .all
        searchText = ""
        titleBar.clearSearch()
        rail.select(index: 0)
        showHostsMode()
    }

    private func connect(to host: Host) {
        let open = Set(portScans[host.ip]?.results.map { $0.port } ?? [])
        var scheme: String?
        var portSuffix = ""
        if open.contains(80) { scheme = "http" }
        else if open.contains(443) { scheme = "https" }
        else if let web = [8080, 8081, 8088, 8000, 8888, 8443, 5000, 9000].first(where: { open.contains($0) }) {
            scheme = "http"; portSuffix = ":\(web)"
        } else if open.contains(445) { scheme = "smb" }
        else if open.contains(548) { scheme = "afp" }
        else if open.contains(5900) { scheme = "vnc" }
        else if open.contains(22) { scheme = "ssh" }

        guard let scheme, let url = URL(string: "\(scheme)://\(host.ip)\(portSuffix)") else {
            let alert = NSAlert()
            alert.messageText = "未发现可连接的服务"
            alert.informativeText = "请先点击「扫描端口」，检测到 HTTP / SMB / AFP / VNC / SSH 等服务后再连接。"
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 根布局

final class RootView: NSView {
    var titleBar: NSView? { didSet { attach(titleBar, at: 10) } }
    var rail: NSView? { didSet { attach(rail, at: 0) } }
    var listView: NSView? { didSet { attach(listView, at: 1) } }
    var detailView: NSView? { didSet { attach(detailView, at: 2) } }
    var wolView: NSView? { didSet { attach(wolView, at: 3) } }

    /// true = 显示网络唤醒管理页，隐藏主机列表与详情
    var wolMode: Bool = false {
        didSet {
            listView?.isHidden = wolMode
            detailView?.isHidden = wolMode
            wolView?.isHidden = !wolMode
            dividerB.isHidden = wolMode
            needsLayout = true
        }
    }

    private let dividerA = Theme.hairline(.zero)
    private let dividerB = Theme.hairline(.zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.window.cgColor
        addSubview(dividerA)
        addSubview(dividerB)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func attach(_ view: NSView?, at index: Int) {
        guard let view else { return }
        addSubview(view, positioned: index == 10 ? .above : .below, relativeTo: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.window.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let barHeight: CGFloat = 52
        let railWidth: CGFloat = 56
        let listWidth: CGFloat = 322

        titleBar?.frame = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        let bodyHeight = height - barHeight
        rail?.frame = NSRect(x: 0, y: 0, width: railWidth, height: bodyHeight)
        dividerA.frame = NSRect(x: railWidth, y: 0, width: 1, height: bodyHeight)
        listView?.frame = NSRect(x: railWidth + 1, y: 0, width: listWidth, height: bodyHeight)
        dividerB.frame = NSRect(x: railWidth + 1 + listWidth, y: 0, width: 1, height: bodyHeight)
        let detailX = railWidth + 2 + listWidth
        detailView?.frame = NSRect(x: detailX, y: 0, width: width - detailX, height: bodyHeight)
        let contentX = railWidth + 1
        wolView?.frame = NSRect(x: contentX, y: 0, width: width - contentX, height: bodyHeight)
        listView?.isHidden = wolMode
        detailView?.isHidden = wolMode
        wolView?.isHidden = !wolMode
        dividerB.isHidden = wolMode
    }
}

// MARK: - 顶部工具栏

final class TitleBarView: NSView {
    var onScan: (() -> Void)?
    var onSettings: (() -> Void)?
    var onSearch: ((String) -> Void)?
    var onInfo: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onHistory: (() -> Void)?
    var onWOL: (() -> Void)?

    private let scanButton = PillButton(title: "扫描",
                                        image: Theme.symbol("dot.radiowaves.left.and.right", size: 14))
    private let wolButton = PillButton(title: "网络唤醒",
                                       image: Theme.symbol("bolt.fill", size: 13))
    private let versionLabel = Theme.label("", size: 10, color: Theme.tertiary)
    private let settingsButton = IconButton(symbol: "gearshape", size: 15, color: Theme.secondary)
    private let infoButton = IconButton(symbol: "info.circle", size: 14, color: Theme.secondary)
    private let refreshButton = IconButton(symbol: "antenna.radiowaves.left.and.right", size: 14, color: Theme.secondary)
    private let historyButton = IconButton(symbol: "clock", size: 14, color: Theme.secondary)
    private let centerGroup = SolidView(color: Theme.card, cornerRadius: 8)
    private let searchField = NSSearchField()
    private let spinner = NSProgressIndicator()
    private let separator = Theme.hairline(.zero)
    private var settingsPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.titleBar.cgColor

        scanButton.contentTintColor = Theme.text
        scanButton.frame = NSRect(x: 128, y: 11, width: 86, height: 30)
        scanButton.target = self
        scanButton.action = #selector(scanTapped)
        addSubview(scanButton)

        settingsButton.frame = NSRect(x: 222, y: 11, width: 34, height: 30)
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        addSubview(settingsButton)

        wolButton.contentTintColor = Theme.text
        wolButton.frame = NSRect(x: 264, y: 11, width: 108, height: 30)
        wolButton.toolTip = "打开网络唤醒 (WOL) 设备列表"
        wolButton.target = self
        wolButton.action = #selector(wolTapped)
        addSubview(wolButton)

        versionLabel.stringValue = "v" + AppVersionInfo.short
        versionLabel.alignment = .right
        versionLabel.toolTip = "点击 ⓘ 查看完整版本与构建信息"
        addSubview(versionLabel)

        addSubview(centerGroup)
        for button in [infoButton, refreshButton, historyButton] {
            centerGroup.addSubview(button)
            button.target = self
        }
        infoButton.action = #selector(infoTapped)
        refreshButton.action = #selector(refreshTapped)
        historyButton.action = #selector(historyTapped)

        searchField.placeholderString = "搜索"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        addSubview(searchField)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        addSubview(separator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.titleBar.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        separator.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        centerGroup.frame = NSRect(x: width / 2 - 66, y: 10, width: 132, height: 32)
        let buttonWidth = centerGroup.bounds.width / 3
        for (index, button) in [infoButton, refreshButton, historyButton].enumerated() {
            button.frame = NSRect(x: CGFloat(index) * buttonWidth, y: 1,
                                  width: buttonWidth, height: 30)
        }
        searchField.frame = NSRect(x: width - 212, y: 11, width: 196, height: 30)
        versionLabel.frame = NSRect(x: width - 296, y: 19, width: 78, height: 14)
        spinner.frame = NSRect(x: 380, y: 17, width: 18, height: 18)
    }

    func setScanning(_ scanning: Bool, text: String = "扫描") {
        scanButton.title = scanning ? "扫描中" : text
        scanButton.isEnabled = !scanning
        if scanning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func clearSearch() {
        searchField.stringValue = ""
        onSearch?("")
    }

    func presentSettings(apply: @escaping () -> Void,
                         onPickNetwork: @escaping () -> Void) {
        if settingsPopover?.isShown == true {
            settingsPopover?.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 344, height: 580)
        let controller = PreferencesViewController()
        controller.onApply = { [weak popover] in
            popover?.close()
            apply()
        }
        controller.onPickNetwork = { [weak popover] in
            popover?.close()
            onPickNetwork()
        }
        popover.contentViewController = controller
        popover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .minY)
        settingsPopover = popover
    }

    @objc private func scanTapped() { onScan?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func infoTapped() { onInfo?() }
    @objc private func refreshTapped() { onRefresh?() }
    @objc private func historyTapped() { onHistory?() }
    @objc private func wolTapped() { onWOL?() }
    @objc private func searchChanged(_ sender: NSSearchField) { onSearch?(sender.stringValue) }
}

// MARK: - 左侧竖排筛选栏

final class RailView: NSView {
    var onSelect: ((Int) -> Void)?
    private var buttons: [IconButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor
        let symbols = ["globe", "network", "eye", "clock", "bolt.fill"]
        let tips = ["全部主机", "网关与路由器", "响应 ping 的主机", "已扫描端口的主机", "网络唤醒 (WOL) 设备列表"]
        for (index, name) in symbols.enumerated() {
            let button = IconButton(symbol: name, size: 19, color: Theme.secondary)
            button.toolTip = tips[index]
            button.tag = index
            button.target = self
            button.action = #selector(buttonTapped(_:))
            addSubview(button)
            buttons.append(button)
        }
        select(index: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sidebar.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 8, y: bounds.height - 62 - CGFloat(index) * 52,
                                  width: 40, height: 42)
        }
    }

    func select(index: Int) {
        for button in buttons { button.isChosen = button.tag == index }
    }

    @objc private func buttonTapped(_ sender: IconButton) {
        select(index: sender.tag)
        onSelect?(sender.tag)
    }
}
