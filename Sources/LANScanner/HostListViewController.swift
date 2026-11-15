import AppKit

// MARK: - 左侧设备列表

final class HostListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var onSelect: ((Host) -> Void)?
    var onScanPorts: ((Host) -> Void)?
    var onAddToWOL: ((Host) -> Void)?
    var onSortChanged: ((SortKey) -> Void)?

    private var hosts: [Host] = []
    private var currentSelectedIP: String?

    private let sortLabel = Theme.label("排序依据", size: 12, color: Theme.tertiary)
    private let sortTabs = SegmentedTabs(titles: ["IP", "名称", "供应商"])
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = Theme.label("尚未扫描", size: 12, color: Theme.tertiary)
    private let topSeparator = Theme.hairline(.zero)
    private let bottomSeparator = Theme.hairline(.zero)
    private let bottomBar = SolidView(color: Theme.list)

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("HostCell")
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("HostRow")

    override func loadView() {
        let root = HostListRootView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.list.cgColor
        view = root

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Hosts"))
        column.width = 320
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 68
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.controlSize = .small
        scrollView.borderType = .noBorder

        sortTabs.onSelect = { [weak self] index in
            self?.onSortChanged?(SortKey(rawValue: index) ?? .ip)
        }

        for item in [sortLabel, sortTabs, scrollView, bottomBar, statusLabel,
                     topSeparator, bottomSeparator] as [NSView] {
            root.addSubview(item)
        }
        root.sortLabel = sortLabel
        root.sortTabs = sortTabs
        root.scrollView = scrollView
        root.statusLabel = statusLabel
        root.topSeparator = topSeparator
        root.bottomSeparator = bottomSeparator
        root.bottomBar = bottomBar
    }

    func update(hosts: [Host], selectedIP: String?, status: String?) {
        self.hosts = hosts
        self.currentSelectedIP = selectedIP
        table.reloadData()
        if let selectedIP, let index = hosts.firstIndex(where: { $0.ip == selectedIP }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
        if let status { setStatus(status) }
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { hosts.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 68 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HostTableRowView()
        rowView.identifier = Self.rowIdentifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? HostRowView) ?? HostRowView()
        cell.identifier = Self.cellIdentifier
        cell.configure(hosts[row], selected: tableView.selectedRow == row,
                       inWOL: WOLStore.shared.contains(mac: hosts[row].mac))
        cell.onScanPorts = { [weak self] host in self?.onScanPorts?(host) }
        cell.onAddToWOL = { [weak self] host in self?.onAddToWOL?(host) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < hosts.count else { return }
        let host = hosts[row]
        guard host.ip != currentSelectedIP else { return }
        currentSelectedIP = host.ip
        onSelect?(host)
    }

    @objc private func tableClicked() {
        let row = table.clickedRow
        guard row >= 0, row < hosts.count else { return }
        let host = hosts[row]
        guard host.ip != currentSelectedIP else { return }
        currentSelectedIP = host.ip
        onSelect?(host)
    }
}

// MARK: - 列表布局

private final class HostListRootView: NSView {
    var sortLabel: NSView?
    var sortTabs: NSView?
    var scrollView: NSScrollView?
    var statusLabel: NSView?
    var topSeparator: NSView?
    var bottomSeparator: NSView?
    var bottomBar: NSView?

    override func draw(_ dirtyRect: NSRect) {
        Theme.list.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let bottomHeight: CGFloat = 30
        let topHeight: CGFloat = 44

        sortLabel?.frame = NSRect(x: 16, y: height - 34, width: 62, height: 18)
        sortTabs?.frame = NSRect(x: 82, y: height - 36, width: width - 98, height: 24)
        topSeparator?.frame = NSRect(x: 0, y: height - topHeight, width: width, height: 1)
        scrollView?.frame = NSRect(x: 0, y: bottomHeight, width: width, height: height - topHeight - bottomHeight)
        bottomBar?.frame = NSRect(x: 0, y: 0, width: width, height: bottomHeight)
        bottomSeparator?.frame = NSRect(x: 0, y: bottomHeight, width: width, height: 1)
        statusLabel?.frame = NSRect(x: 16, y: 7, width: width - 32, height: 16)
        if let column = (scrollView?.documentView as? NSTableView)?.tableColumns.first {
            column.width = width - 2
        }
    }
}

// MARK: - 选中行高亮

final class HostTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 8, yRadius: 8).fill()
    }
}

// MARK: - 列表行

final class HostRowView: NSTableCellView {
    var onScanPorts: ((Host) -> Void)?
    var onAddToWOL: ((Host) -> Void)?
    private var host: Host?

    private let icon = DeviceIconView(frame: .zero)
    private let titleField = Theme.label("", size: 15, weight: .semibold)
    private let vendorField = Theme.label("", size: 12, color: Theme.secondary)
    private let ipField = Theme.label("", size: 11, color: Theme.tertiary)
    private let wolButton = IconButton(symbol: "bolt.fill", size: 13, color: Theme.tertiary)
    private let scanButton = IconButton(symbol: "chevron.right", size: 13, color: Theme.tertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scanButton.target = self
        scanButton.action = #selector(scanTapped)
        scanButton.toolTip = "扫描该设备的端口"
        wolButton.target = self
        wolButton.action = #selector(wolTapped)
        wolButton.toolTip = "加入 / 打开网络唤醒列表"
        for subview in [icon, titleField, vendorField, ipField, wolButton, scanButton] as [NSView] {
            addSubview(subview)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ host: Host, selected: Bool, inWOL: Bool = false) {
        self.host = host
        icon.mode = host.isGateway ? .gateway : .host
        titleField.stringValue = host.ip
        vendorField.stringValue = host.note.isEmpty ? host.displayName : host.displayName + " · " + host.note
        // 有设备名时第三行显示厂商，否则保持截图样式显示带间隔的 IP
        ipField.stringValue = host.hostname == nil
            ? host.ip.replacingOccurrences(of: ".", with: ". ")
            : host.vendor
        let subtle = selected ? NSColor.white.withAlphaComponent(0.72) : Theme.tertiary
        let middle = selected ? NSColor.white.withAlphaComponent(0.88) : Theme.secondary
        titleField.textColor = .white
        vendorField.textColor = middle
        ipField.textColor = subtle
        wolButton.contentTintColor = inWOL ? Theme.green : (selected ? .white : Theme.tertiary)
        wolButton.toolTip = inWOL ? "已在唤醒列表中 · 点击查看" : "加入网络唤醒列表"
        wolButton.isEnabled = host.mac != nil
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        icon.frame = NSRect(x: 14, y: 12, width: 44, height: 44)
        let textX: CGFloat = 70
        let textWidth = width - textX - 68
        titleField.frame = NSRect(x: textX, y: 39, width: textWidth, height: 20)
        vendorField.frame = NSRect(x: textX, y: 21, width: textWidth, height: 17)
        ipField.frame = NSRect(x: textX, y: 5, width: textWidth, height: 14)
        wolButton.frame = NSRect(x: width - 62, y: 22, width: 24, height: 24)
        scanButton.frame = NSRect(x: width - 34, y: 22, width: 24, height: 24)
    }

    @objc private func scanTapped() {
        if let host { onScanPorts?(host) }
    }

    @objc private func wolTapped() {
        if let host { onAddToWOL?(host) }
    }
}
