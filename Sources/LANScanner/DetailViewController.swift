import AppKit

enum DetailTab: Int {
    case services = 0, ports = 1
}

// MARK: - 右侧详情面板

final class DetailViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var onScanPorts: ((Host) -> Void)?
    var onCancelPorts: (() -> Void)?
    var onNoteChanged: ((String, String) -> Void)?
    var onConnect: ((Host) -> Void)?
    var onWOLAction: ((Host) -> Void)?

    private var host: Host?
    private var outcome: PortScanOutcome?
    private var scanning = false
    private var tab: DetailTab = .services

    private var portRows: [PortResult] { outcome?.results ?? [] }
    private var serviceRows: [PortResult] { portRows.filter { $0.service != "未知服务" } }

    private let globe = GlobeIconView()
    private let ipTitle = Theme.label("", size: 34, weight: .light)
    private let vendorField = Theme.label("", size: 14, color: Theme.secondary)
    private let deviceNameField = Theme.label("", size: 12, color: Theme.secondary)
    private let ipKey = Theme.label("IP:", size: 13, color: Theme.secondary)
    private let ipValue = Theme.monospaceLabel("", size: 13)
    private let macKey = Theme.label("MAC:", size: 13, color: Theme.secondary)
    private let macValue = Theme.monospaceLabel("", size: 13)
    private let noteField = Theme.label("", size: 12, color: Theme.secondary)
    private let noteButton = PillButton(title: "备注")
    private let connectButton = PillButton(title: "连接")
    private let wolButton = PillButton(title: "加入 WOL")
    private let wolStatusField = Theme.label("", size: 11, color: Theme.tertiary)
    private let statusLabel = Theme.label("主机可达", size: 12, color: Theme.secondary)
    private let statusDot = DotView()
    private let tabs = SegmentedTabs(titles: ["服务", "端口"])
    private let scanButton = PillButton(title: "扫描端口")
    private let foundBlock = InfoBlockView()
    private let routeBlock = InfoBlockView()
    private let progressLabel = Theme.label("", size: 12, color: Theme.secondary)
    private let progressBar = NSProgressIndicator()
    private let summaryLabel = Theme.label("", size: 12, color: Theme.secondary)
    private let emptyState = EmptyStateView()
    private let portTable = NSTableView()
    private let portScroll = NSScrollView()
    private let serviceTable = NSTableView()
    private let serviceScroll = NSScrollView()

    override func loadView() {
        let root = DetailRootView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.detail.cgColor
        view = root

        statusDot.color = Theme.green

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0

        configure(table: portTable, columns: [
            ("p.port", "端口", 90), ("p.service", "服务", 160), ("p.state", "状态", 90),
            ("p.rtt", "响应时间", 110), ("p.banner", "服务横幅 / 描述", 320)
        ])
        configure(table: serviceTable, columns: [
            ("s.service", "服务", 190), ("s.port", "端口", 100),
            ("s.proto", "协议", 100), ("s.note", "说明", 320)
        ])
        portScroll.documentView = portTable
        serviceScroll.documentView = serviceTable
        for scroll in [portScroll, serviceScroll] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 6
        }

        noteButton.target = self
        noteButton.action = #selector(noteTapped)
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        wolButton.target = self
        wolButton.action = #selector(wolTapped)
        scanButton.target = self
        scanButton.action = #selector(scanTapped)
        scanButton.fillColor = Theme.button

        tabs.onSelect = { [weak self] index in
            guard let self else { return }
            self.tab = DetailTab(rawValue: index) ?? .services
            if self.tab == .ports, !self.scanning, self.outcome == nil, let host = self.host {
                self.onScanPorts?(host)
            }
            self.refreshContent()
        }

        let subviews: [NSView] = [
            globe, ipTitle, vendorField, deviceNameField, ipKey, ipValue, macKey, macValue, noteField,
            noteButton, connectButton, wolButton, wolStatusField,
            statusLabel, statusDot, tabs, scanButton,
            foundBlock, routeBlock, progressLabel, progressBar, summaryLabel,
            emptyState, portScroll, serviceScroll
        ]
        for subview in subviews { root.addSubview(subview) }

        root.globe = globe
        root.ipTitle = ipTitle
        root.vendorField = vendorField
        root.deviceNameField = deviceNameField
        root.ipKey = ipKey
        root.ipValue = ipValue
        root.macKey = macKey
        root.macValue = macValue
        root.noteField = noteField
        root.noteButton = noteButton
        root.connectButton = connectButton
        root.wolButton = wolButton
        root.wolStatusField = wolStatusField
        root.statusLabel = statusLabel
        root.statusDot = statusDot
        root.tabs = tabs
        root.scanButton = scanButton
        root.foundBlock = foundBlock
        root.routeBlock = routeBlock
        root.progressLabel = progressLabel
        root.progressBar = progressBar
        root.summaryLabel = summaryLabel
        root.emptyState = emptyState
        root.portScroll = portScroll
        root.serviceScroll = serviceScroll

        showEmpty()
    }

    private func configure(table: NSTableView, columns: [(String, String, CGFloat)]) {
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
    }

    // MARK: 状态刷新

    func show(host: Host, outcome: PortScanOutcome?, scanning: Bool) {
        self.host = host
        self.outcome = outcome
        self.scanning = scanning

        ipTitle.stringValue = host.ip
        vendorField.stringValue = host.vendor
        if let hostname = host.hostname, !hostname.isEmpty {
            deviceNameField.stringValue = "设备名：\(hostname)"
            deviceNameField.isHidden = false
        } else {
            deviceNameField.stringValue = ""
            deviceNameField.isHidden = true
        }
        ipValue.stringValue = host.ip
        macValue.stringValue = host.mac ?? "—"
        noteField.stringValue = host.note.isEmpty ? "" : "备注：" + host.note
        statusLabel.stringValue = host.isReachable ? "主机可达" : "仅在 ARP 缓存中"
        statusDot.color = host.isReachable ? Theme.green : Theme.amber
        statusDot.isHidden = false
        wolButton.isHidden = false
        wolStatusField.isHidden = false
        updateWOLState(for: host)

        foundBlock.configure(symbol: "dot.radiowaves.left.and.right",
                             title: "扫描期间找到", subtitle: host.statusText)
        routeBlock.configure(symbol: host.isGateway ? "network" : "display",
                             title: host.isGateway ? "主机是网关" : "局域网主机",
                             subtitle: host.isGateway ? "流量通过该主机进行路由" : "该主机不是默认网关")

        scanButton.title = scanning ? "停止扫描" : (outcome == nil ? "扫描端口" : "重新扫描")
        if let outcome {
            summaryLabel.stringValue = String(format: "已扫描 %d 个端口 · 发现 %d 个开放 · 耗时 %.2fs",
                                              outcome.scanned, outcome.results.count, outcome.elapsed)
        } else {
            summaryLabel.stringValue = "尚未对该设备执行端口扫描"
        }
        progressLabel.stringValue = scanning ? "正在扫描端口…" : ""
        progressBar.isHidden = !scanning
        summaryLabel.isHidden = scanning
        progressLabel.isHidden = !scanning
        summaryLabel.isHidden = scanning || outcome == nil
        portTable.reloadData()
        serviceTable.reloadData()
        refreshContent()
    }

    func showEmpty() {
        host = nil
        outcome = nil
        scanning = false
        ipTitle.stringValue = "LANScanner"
        vendorField.stringValue = "点击顶部「扫描」发现局域网设备，选中设备后可扫描其开放端口"
        deviceNameField.isHidden = true
        ipValue.stringValue = "—"
        macValue.stringValue = "—"
        noteField.stringValue = ""
        statusLabel.stringValue = ""
        statusDot.isHidden = true
        wolButton.isHidden = true
        wolStatusField.isHidden = true
        foundBlock.configure(symbol: "dot.radiowaves.left.and.right",
                             title: "等待扫描", subtitle: "尚未发现主机")
        routeBlock.configure(symbol: "network", title: "网段信息", subtitle: "扫描后显示网关信息")
        summaryLabel.stringValue = ""
        progressLabel.isHidden = true
        progressBar.isHidden = true
        scanButton.title = "扫描端口"
        portTable.reloadData()
        serviceTable.reloadData()
        refreshContent()
    }

    func selectTab(_ tab: DetailTab) {
        self.tab = tab
        tabs.selectedIndex = tab.rawValue
        refreshContent()
    }

    func setPortProgress(_ done: Int, total: Int) {
        guard scanning else { return }
        progressLabel.stringValue = "正在扫描端口 · \(done)/\(total)"
        progressBar.doubleValue = total > 0 ? Double(done) / Double(total) * 100 : 0
    }

    private func refreshContent() {
        let isPortsTab = tab == .ports
        portScroll.isHidden = !isPortsTab || shouldShowEmpty
        serviceScroll.isHidden = isPortsTab || shouldShowEmpty
        emptyState.isHidden = !shouldShowEmpty
        emptyState.setText(emptyMessage)
        tabs.selectedIndex = tab.rawValue
    }

    private var shouldShowEmpty: Bool {
        if scanning { return false }
        return tab == .ports ? portRows.isEmpty : serviceRows.isEmpty
    }

    private var emptyMessage: String {
        if tab == .ports {
            return outcome == nil ? "点击「扫描端口」检测该设备开放的端口" : "未发现开放端口"
        }
        return "未发现服务"
    }

    // MARK: 表格数据

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === portTable ? portRows.count : serviceRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let key = tableColumn?.identifier.rawValue ?? "cell"
        let identifier = NSUserInterfaceItemIdentifier(key)
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TextCellView) ?? TextCellView()
        cell.identifier = identifier

        let result: PortResult
        if tableView === portTable {
            result = portRows[row]
            switch key {
            case "p.port": cell.setText("\(result.port)", emphasized: true)
            case "p.service": cell.setText(result.service)
            case "p.state": cell.setText("开放", color: Theme.green)
            case "p.rtt": cell.setText(String(format: "%.1f ms", result.responseMs ?? 0))
            case "p.banner": cell.setText(result.banner.isEmpty ? "—" : result.banner, color: Theme.secondary)
            default: cell.setText("")
            }
        } else {
            result = serviceRows[row]
            switch key {
            case "s.service": cell.setText(result.service, emphasized: true)
            case "s.port": cell.setText("\(result.port)")
            case "s.proto": cell.setText("TCP")
            case "s.note": cell.setText(result.banner.isEmpty ? "TCP \(result.port) 端口开放" : result.banner,
                                        color: Theme.secondary)
            default: cell.setText("")
            }
        }
        return cell
    }

    // MARK: 网络唤醒状态

    func updateWOLState(for host: Host) {
        let inWOL = WOLStore.shared.contains(mac: host.mac)
        wolButton.title = inWOL ? "网络唤醒" : "加入 WOL"
        wolButton.isEnabled = inWOL || host.mac != nil
        if inWOL, let device = WOLStore.shared.device(mac: host.mac ?? "") {
            wolStatusField.stringValue = "WOL：已在唤醒列表 · 累计唤醒 \(device.wakeCount) 次 · 上次 \(device.lastWakeText)"
        } else {
            wolStatusField.stringValue = host.mac == nil
                ? "WOL：未获取到 MAC 地址，无法加入唤醒列表"
                : "WOL：加入列表后可发送 Magic Packet 远程唤醒该设备"
        }
    }

    // MARK: 按钮动作

    @objc private func scanTapped() {
        if scanning {
            onCancelPorts?()
            return
        }
        guard let host else { return }
        onScanPorts?(host)
    }

    @objc private func noteTapped() {
        guard var host = host else { return }
        let alert = NSAlert()
        alert.messageText = "备注"
        alert.informativeText = "为 \(host.ip) 添加备注，备注会保存在本机。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = host.note
        input.placeholderString = "例如：客厅电视"
        input.bezelStyle = .roundedBezel
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            host.note = text
            self.host = host
            noteField.stringValue = text.isEmpty ? "" : "备注：" + text
            onNoteChanged?(host.ip, text)
        }
    }

    @objc private func connectTapped() {
        guard let host else { return }
        onConnect?(host)
    }

    @objc private func wolTapped() {
        guard let host else { return }
        onWOLAction?(host)
    }
}

// MARK: - 详情面板布局

private final class DetailRootView: NSView {
    var globe: NSView?
    var ipTitle: NSView?
    var vendorField: NSView?
    var deviceNameField: NSView?
    var ipKey: NSView?
    var ipValue: NSView?
    var macKey: NSView?
    var macValue: NSView?
    var noteField: NSView?
    var noteButton: NSView?
    var connectButton: NSView?
    var wolButton: NSView?
    var wolStatusField: NSView?
    var statusLabel: NSView?
    var statusDot: NSView?
    var tabs: NSView?
    var scanButton: NSView?
    var foundBlock: NSView?
    var routeBlock: NSView?
    var progressLabel: NSView?
    var progressBar: NSView?
    var summaryLabel: NSView?
    var emptyState: NSView?
    var portScroll: NSScrollView?
    var serviceScroll: NSScrollView?

    private func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x, y: bounds.height - top - height, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.detail.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let textX: CGFloat = 238
        let textWidth = max(160, width - textX - 24)
        let tabsX = max(36, width * 0.22)

        globe?.frame = rect(44, 40, 156, 156)
        ipTitle?.frame = rect(textX, 48, textWidth, 46)
        vendorField?.frame = rect(textX, 98, textWidth, 22)
        deviceNameField?.frame = rect(textX, 120, textWidth, 18)
        ipKey?.frame = rect(textX, 140, 40, 20)
        ipValue?.frame = rect(textX + 46, 140, max(120, textWidth - 46), 20)
        macKey?.frame = rect(textX, 166, 46, 20)
        macValue?.frame = rect(textX + 52, 166, max(120, textWidth - 52), 20)
        noteField?.frame = rect(textX, 192, textWidth, 18)
        noteButton?.frame = rect(textX, 218, 66, 28)
        connectButton?.frame = rect(textX + 76, 218, 66, 28)
        wolButton?.frame = rect(textX + 152, 218, 92, 28)
        wolStatusField?.frame = rect(textX, 250, max(120, width - textX - 176), 18)
        statusLabel?.frame = rect(width - 158, 250, 100, 18)
        statusDot?.frame = rect(width - 52, 254, 9, 9)

        tabs?.frame = rect(tabsX, 286, 150, 28)
        scanButton?.frame = rect(tabsX + 160, 286, 96, 28)
        foundBlock?.frame = rect(width - 254, 298, 234, 44)
        routeBlock?.frame = rect(width - 254, 348, 234, 44)

        progressLabel?.frame = rect(40, 360, width - 80, 18)
        summaryLabel?.frame = rect(40, 360, width - 80, 18)
        progressBar?.frame = rect(40, 384, width - 80, 8)

        let tableTop: CGFloat = 406
        let tableHeight = max(90, height - tableTop - 26)
        let tableRect = rect(40, tableTop, max(320, width - 80), tableHeight)
        portScroll?.frame = tableRect
        serviceScroll?.frame = tableRect

        let emptyTop = max(tableTop + 16, height * 0.54)
        emptyState?.frame = rect(width * 0.32 - 110, emptyTop, 220, 150)

        if let table = portScroll?.documentView as? NSTableView, table.tableColumns.count == 5 {
            let available = tableRect.width - 20
            let fixed: [CGFloat] = [90, 160, 90, 110]
            for (index, column) in table.tableColumns.enumerated() {
                column.width = index < 4 ? fixed[index] : max(220, available - fixed.reduce(0, +))
            }
        }
        if let table = serviceScroll?.documentView as? NSTableView, table.tableColumns.count == 4 {
            let available = tableRect.width - 20
            let fixed: [CGFloat] = [190, 100, 100]
            for (index, column) in table.tableColumns.enumerated() {
                column.width = index < 3 ? fixed[index] : max(220, available - fixed.reduce(0, +))
            }
        }
    }
}

// MARK: - 辅助视图

final class TextCellView: NSTableCellView {
    private let field = Theme.label("", size: 12, color: Theme.text)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String, emphasized: Bool = false, color: NSColor = Theme.text) {
        field.stringValue = text
        field.font = NSFont.systemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
        field.textColor = color
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 8, y: 3, width: bounds.width - 16, height: bounds.height - 6)
    }
}

final class InfoBlockView: NSView {
    private let imageView = NSImageView()
    private let titleField = Theme.label("", size: 12, weight: .semibold, color: Theme.secondary)
    private let subtitleField = Theme.label("", size: 11, color: Theme.tertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [imageView, titleField, subtitleField] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, title: String, subtitle: String) {
        imageView.image = Theme.symbol(symbol, size: 18)
        imageView.contentTintColor = Theme.tertiary
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
    }

    override func layout() {
        super.layout()
        imageView.frame = NSRect(x: 0, y: 8, width: 26, height: 26)
        titleField.frame = NSRect(x: 34, y: bounds.height - 20, width: bounds.width - 34, height: 17)
        subtitleField.frame = NSRect(x: 34, y: bounds.height - 37, width: bounds.width - 34, height: 16)
    }
}

final class EmptyStateView: NSView {
    private let icon = CycleIconView()
    private let label = Theme.label("未发现服务", size: 14, color: Theme.secondary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(icon)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String) { label.stringValue = text }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: bounds.midX - 46, y: bounds.height - 96, width: 92, height: 92)
        label.frame = NSRect(x: 0, y: bounds.height - 132, width: bounds.width, height: 22)
        label.alignment = .center
    }
}
