import AppKit

// MARK: - 扫描网络选择窗口（参照 inet network scanner 的接口选择面板）

final class NetworkPickerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    var onScan: ((LocalNetwork) -> Void)?
    var onCancel: (() -> Void)?

    private let networks: [LocalNetwork]
    private var selectedIndex: Int = 0

    private let iconView = NSImageView()
    private let interfaceLabel = Theme.label("通过网络接口：", size: 13, color: Theme.secondary)
    private let manualLabel = Theme.label("手动：", size: 13, color: Theme.secondary)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let startLabel = Theme.label("起始 IP:", size: 12, color: Theme.secondary)
    private let endLabel = Theme.label("结束 IP:", size: 12, color: Theme.secondary)
    private let startField = DarkTextField()
    private let endField = DarkTextField()
    private let manualCheckbox = CheckToggle(title: "使用手动 IP 范围")
    private let timeoutLabel = Theme.label("超时：", size: 12, color: Theme.secondary)
    private let timeoutSegments = SegmentedTabs(titles: ["低", "中", "高"])
    private let hintLabel = Theme.label("选择接口会自动填充扫描范围；勾选手动范围后可自定义起止 IP。",
                                        size: 11, color: Theme.tertiary)
    private let cancelButton = PillButton(title: "取消")
    private let scanButton = PillButton(title: "扫描")
    private let separator = Theme.hairline(.zero)

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("InterfaceCell")
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("InterfaceRow")

    init(networks: [LocalNetwork]) {
        self.networks = networks
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "选择扫描网络"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.window
        window.isMovableByWindowBackground = true
        super.init(window: window)

        let root = PickerRootView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.window.cgColor
        window.contentView = root
        buildUI(in: root)
        loadInitialSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI(in root: PickerRootView) {
        iconView.image = Theme.symbol("display", size: 30)
        iconView.contentTintColor = Theme.iconBlue
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = Theme.card.cgColor
        iconView.layer?.cornerRadius = 10

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Interfaces"))
        column.width = 234
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .white
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        // 接口数量很少，隐藏系统滚动条避免其白色轨道遮挡右侧标签
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder

        // DarkTextField 自带深色底，无需额外样式
        manualCheckbox.target = self
        manualCheckbox.action = #selector(manualToggled)

        timeoutSegments.onSelect = { index in
            ScanSettings.shared.timeoutLevel = index
        }

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        scanButton.target = self
        scanButton.action = #selector(scanTapped)
        scanButton.isChosen = true

        let subviews: [NSView] = [iconView, interfaceLabel, manualLabel, scrollView,
                                  startLabel, startField, endLabel, endField, manualCheckbox,
                                  timeoutLabel, timeoutSegments, hintLabel, cancelButton,
                                  scanButton, separator]
        for view in subviews { root.addSubview(view) }

        root.iconView = iconView
        root.interfaceLabel = interfaceLabel
        root.manualLabel = manualLabel
        root.scrollView = scrollView
        root.startLabel = startLabel
        root.startField = startField
        root.endLabel = endLabel
        root.endField = endField
        root.manualCheckbox = manualCheckbox
        root.timeoutLabel = timeoutLabel
        root.timeoutSegments = timeoutSegments
        root.hintLabel = hintLabel
        root.cancelButton = cancelButton
        root.scanButton = scanButton
        root.separator = separator
    }

    private func loadInitialSelection() {
        let settings = ScanSettings.shared
        if let index = networks.firstIndex(where: { $0.interface == settings.selectedInterface }) {
            selectedIndex = index
        } else if let index = networks.firstIndex(where: { $0.isDefaultRoute }) {
            selectedIndex = index
        }
        timeoutSegments.selectedIndex = Swift.min(Swift.max(settings.timeoutLevel, 0), 2)
        if settings.useManualRange {
            manualCheckbox.setOn(true)
            startField.stringValue = settings.manualStartIP
            endField.stringValue = settings.manualEndIP
        } else {
            fillRangeFromSelection()
        }
        updateManualState()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    /// 仅用于离屏预览：展示「使用手动 IP 范围」勾选后的状态
    func showManualPreview() {
        manualCheckbox.setOn(true)
        updateManualState()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func fillRangeFromSelection() {
        guard networks.indices.contains(selectedIndex) else { return }
        let network = networks[selectedIndex]
        startField.stringValue = network.rangeStart
        endField.stringValue = network.rangeEnd
    }

    private func updateManualState() {
        let manual = manualCheckbox.state == .on
        startLabel.textColor = manual ? Theme.text : Theme.secondary
        endLabel.textColor = manual ? Theme.text : Theme.secondary
        // 未勾选时起止 IP 由所选接口自动填充，勾选后才允许编辑
        startField.isEditable = manual
        endField.isEditable = manual
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { networks.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 64 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = InterfaceRowView()
        rowView.identifier = Self.rowIdentifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? InterfaceCellView)
            ?? InterfaceCellView()
        cell.identifier = Self.cellIdentifier
        cell.configure(networks[row], selected: row == selectedIndex)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0 else { return }
        selectedIndex = tableView.selectedRow
        if manualCheckbox.state == .off { fillRangeFromSelection() }
        tableView.reloadData()
    }

    @objc private func tableClicked() {
        guard tableView.clickedRow >= 0 else { return }
        selectedIndex = tableView.clickedRow
        if manualCheckbox.state == .off { fillRangeFromSelection() }
        tableView.reloadData()
    }

    // MARK: 动作

    @objc private func manualToggled() {
        // 状态切换与重绘由 CheckToggle.toggle() 完成，这里只处理联动副作用
        if manualCheckbox.state == .off { fillRangeFromSelection() }
        updateManualState()
    }

    @objc private func cancelTapped() {
        close()
        onCancel?()
    }

    @objc private func scanTapped() {
        guard networks.indices.contains(selectedIndex) else { return }
        let chosen = networks[selectedIndex]
        guard chosen.isScannable else {
            let alert = NSAlert()
            alert.messageText = "该网络接口未连接"
            alert.informativeText = "请选择一个显示「已连接」的接口，或勾选手动 IP 范围。"
            alert.runModal()
            return
        }

        var network = chosen
        let useManual = manualCheckbox.state == .on
        if useManual {
            guard let ranged = chosen.withRange(start: startField.stringValue, end: endField.stringValue) else {
                let alert = NSAlert()
                alert.messageText = "IP 范围无效"
                alert.informativeText = "请检查起始 / 结束 IP 格式，且结束 IP 不小于起始 IP。"
                alert.runModal()
                return
            }
            network = ranged
        }

        let settings = ScanSettings.shared
        settings.selectedInterface = chosen.interface
        settings.useManualRange = useManual
        settings.manualStartIP = startField.stringValue
        settings.manualEndIP = endField.stringValue
        settings.timeoutLevel = timeoutSegments.selectedIndex

        close()
        onScan?(network)
    }
}

// MARK: - 布局

private final class PickerRootView: NSView {
    var iconView: NSView?
    var interfaceLabel: NSView?
    var manualLabel: NSView?
    var scrollView: NSScrollView?
    var startLabel: NSView?
    var startField: NSView?
    var endLabel: NSView?
    var endField: NSView?
    var manualCheckbox: NSView?
    var timeoutLabel: NSView?
    var timeoutSegments: NSView?
    var hintLabel: NSView?
    var cancelButton: NSView?
    var scanButton: NSView?
    var separator: NSView?

    private func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x, y: bounds.height - top - height, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.window.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        iconView?.frame = rect(20, 16, 52, 52)
        interfaceLabel?.frame = rect(88, 30, 180, 20)
        manualLabel?.frame = rect(300, 30, 100, 20)

        scrollView?.frame = rect(20, 76, 236, 226)
        if let column = (scrollView?.documentView as? NSTableView)?.tableColumns.first {
            column.width = 234
        }

        startLabel?.frame = rect(296, 82, 60, 20)
        startField?.frame = rect(358, 80, 180, 24)
        endLabel?.frame = rect(296, 114, 60, 20)
        endField?.frame = rect(358, 112, 180, 24)
        manualCheckbox?.frame = rect(296, 146, 230, 22)
        timeoutLabel?.frame = rect(296, 182, 50, 20)
        timeoutSegments?.frame = rect(348, 180, 190, 24)
        hintLabel?.frame = rect(296, 212, 242, 44)
        if let field = hintLabel as? NSTextField {
            field.usesSingleLineMode = false
            field.lineBreakMode = .byWordWrapping
        }

        separator?.frame = rect(20, height - 66, width - 40, 1)
        cancelButton?.frame = rect(width - 178, height - 54, 70, 30)
        scanButton?.frame = rect(width - 98, height - 54, 78, 30)
    }
}

// MARK: - 接口列表行

final class InterfaceRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.accent.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

final class InterfaceCellView: NSTableCellView {
    private var isSelectedRow = false
    private let iconView = NSImageView()
    private let nameField = Theme.label("", size: 13, weight: .semibold, color: .black)
    private let statusField = Theme.label("", size: 11, color: NSColor(calibratedWhite: 0.35, alpha: 1))
    private let rangeField = Theme.label("", size: 11, color: NSColor(calibratedWhite: 0.45, alpha: 1))
    private let dot = DotView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [iconView, nameField, statusField, rangeField, dot] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        (isSelectedRow ? Theme.accent : .white).setFill()
        NSBezierPath(rect: bounds).fill()
        super.draw(dirtyRect)
    }

    func configure(_ network: LocalNetwork, selected: Bool) {
        isSelectedRow = selected
        needsDisplay = true
        let wifi = network.name.lowercased().contains("wi-fi") || network.name.lowercased().contains("wifi")
        iconView.image = Theme.symbol(wifi ? "wifi" : "network", size: 17)
        iconView.contentTintColor = selected ? .white : NSColor(calibratedWhite: 0.35, alpha: 1)
        nameField.stringValue = network.displayName
        statusField.stringValue = network.isActive ? "已连接 - IP: \(network.ip)" : "未连接"
        rangeField.stringValue = network.rangeLabel
        dot.color = network.isActive ? Theme.green : NSColor(srgbRed: 0.86, green: 0.24, blue: 0.24, alpha: 1)

        let textColor: NSColor = selected ? .white : .black
        let subtle: NSColor = selected ? NSColor.white.withAlphaComponent(0.85) : NSColor(calibratedWhite: 0.35, alpha: 1)
        nameField.textColor = textColor
        statusField.textColor = subtle
        rangeField.textColor = subtle
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 12, y: 22, width: 22, height: 22)
        nameField.frame = NSRect(x: 44, y: 40, width: bounds.width - 70, height: 18)
        statusField.frame = NSRect(x: 44, y: 22, width: bounds.width - 76, height: 16)
        rangeField.frame = NSRect(x: 44, y: 5, width: bounds.width - 70, height: 16)
        dot.frame = NSRect(x: bounds.width - 22, y: 26, width: 9, height: 9)
    }
}
