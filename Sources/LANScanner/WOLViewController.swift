import AppKit

// MARK: - 网络唤醒（WOL）管理页面

final class WOLViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// 「添加选中主机」：由主窗口把当前扫描列表选中的设备加入
    var onAddScannedSelection: (() -> Void)?
    /// 列表发生变化（加入 / 移除 / 编辑）后通知主窗口刷新按钮状态
    var onDevicesChanged: (() -> Void)?

    private var devices: [WOLDevice] = []
    private var filtered: [WOLDevice] = []
    private var selectedMAC: String?
    private var searchText = ""
    /// 仅用于 --uirender 预览，不读写真实存储
    private var previewMode = false

    private let listTitle = Theme.label("网络唤醒设备", size: 15, weight: .semibold)
    private let countLabel = Theme.label("", size: 12, color: Theme.secondary)
    private let addScannedButton = PillButton(title: "添加选中主机")
    private let addManualButton = PillButton(title: "手动添加")
    private let wakeAllButton = PillButton(title: "全部唤醒")
    private let removeButton = PillButton(title: "移除")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let listHint = Theme.label("点设备行电源按钮加入，或手动添加 MAC 地址。",
                                       size: 11, color: Theme.tertiary)
    private let divider = Theme.hairline(.zero)

    private let powerIcon = PowerIconView()
    private let deviceTitle = Theme.label("", size: 28, weight: .light)
    private let deviceSubtitle = Theme.label("", size: 13, color: Theme.secondary)
    private let macKey = Theme.label("MAC:", size: 12, color: Theme.secondary)
    private let macValue = Theme.monospaceLabel("", size: 12)
    private let ipKey = Theme.label("IP:", size: 12, color: Theme.secondary)
    private let ipValue = Theme.monospaceLabel("", size: 12)
    private let vendorKey = Theme.label("厂商:", size: 12, color: Theme.secondary)
    private let vendorValue = Theme.label("", size: 12)
    private let wakeInfo = Theme.label("", size: 12, color: Theme.secondary)

    private let nameEditLabel = Theme.label("设备名称", size: 12, color: Theme.secondary)
    private let nameEditField = DarkTextField()
    private let broadcastEditLabel = Theme.label("广播地址（可选）", size: 12, color: Theme.secondary)
    private let broadcastEditField = DarkTextField()
    private let portEditLabel = Theme.label("唤醒端口", size: 12, color: Theme.secondary)
    private let portDropdown = DropdownButton(options: WOLPortMode.optionTitles)
    private let saveDeviceButton = PillButton(title: "保存修改")
    private let editHint = Theme.label("广播地址留空则自动使用子网定向广播与 255.255.255.255。",
                                       size: 11, color: Theme.tertiary)

    private let wakeButton = PillButton(title: "发送唤醒包")
    private let resultLabel = Theme.label("", size: 12, color: Theme.secondary)
    private let verifyCheckbox = CheckToggle(title: "唤醒后检测设备是否上线")
    private let note1 = Theme.label("· 目标设备网卡需支持并已启用 WoL，且保持供电与网线连接。",
                                    size: 11, color: Theme.tertiary)
    private let note2 = Theme.label("· Magic Packet 通过 UDP 广播发送，仅能作用于同一二层网络。",
                                    size: 11, color: Theme.tertiary)
    private let note3 = Theme.label("· 协议无确认机制，「发送成功」不代表设备一定已开机。",
                                    size: 11, color: Theme.tertiary)

    private static let cellID = NSUserInterfaceItemIdentifier("WOLCell")
    private static let rowID = NSUserInterfaceItemIdentifier("WOLRow")

    override func loadView() {
        let root = WOLRootView()
        view = root

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WOLDevices"))
        column.width = 340
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        scroll.borderType = .noBorder

        addScannedButton.target = self
        addScannedButton.action = #selector(addScannedTapped)
        addManualButton.target = self
        addManualButton.action = #selector(addManualTapped)
        wakeAllButton.target = self
        wakeAllButton.action = #selector(wakeAllTapped)
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        wakeButton.target = self
        wakeButton.action = #selector(wakeTapped)
        wakeButton.isChosen = true
        saveDeviceButton.target = self
        saveDeviceButton.action = #selector(saveDeviceTapped)
        verifyCheckbox.target = self
        verifyCheckbox.action = #selector(verifyToggled)

        broadcastEditField.placeholderString = "例如 192.168.31.255（可选）"
        nameEditField.placeholderString = "给设备起个名字"
        resultLabel.lineBreakMode = .byWordWrapping
        resultLabel.maximumNumberOfLines = 4
        resultLabel.cell?.wraps = true
        resultLabel.cell?.isScrollable = false

        let subviews: [NSView] = [
            listTitle, countLabel, addScannedButton, addManualButton, wakeAllButton,
            removeButton, scroll, listHint, divider,
            powerIcon, deviceTitle, deviceSubtitle, macKey, macValue, ipKey, ipValue,
            vendorKey, vendorValue, wakeInfo,
            nameEditLabel, nameEditField, broadcastEditLabel, broadcastEditField,
            portEditLabel, portDropdown, saveDeviceButton, editHint,
            wakeButton, resultLabel, verifyCheckbox, note1, note2, note3
        ]
        for subview in subviews { root.addSubview(subview) }

        root.listTitle = listTitle
        root.countLabel = countLabel
        root.addScannedButton = addScannedButton
        root.addManualButton = addManualButton
        root.wakeAllButton = wakeAllButton
        root.removeButton = removeButton
        root.scroll = scroll
        root.listHint = listHint
        root.divider = divider
        root.powerIcon = powerIcon
        root.deviceTitle = deviceTitle
        root.deviceSubtitle = deviceSubtitle
        root.macKey = macKey
        root.macValue = macValue
        root.ipKey = ipKey
        root.ipValue = ipValue
        root.vendorKey = vendorKey
        root.vendorValue = vendorValue
        root.wakeInfo = wakeInfo
        root.nameEditLabel = nameEditLabel
        root.nameEditField = nameEditField
        root.broadcastEditLabel = broadcastEditLabel
        root.broadcastEditField = broadcastEditField
        root.portEditLabel = portEditLabel
        root.portDropdown = portDropdown
        root.saveDeviceButton = saveDeviceButton
        root.editHint = editHint
        root.wakeButton = wakeButton
        root.resultLabel = resultLabel
        root.verifyCheckbox = verifyCheckbox
        root.note1 = note1
        root.note2 = note2
        root.note3 = note3

        verifyCheckbox.state = ScanSettings.shared.wolVerifyAfterWake ? .on : .off
        reload()
    }

    // MARK: 数据

    func reload() {
        if !previewMode { devices = WOLStore.shared.devices() }
        applyFilter()
        if let selectedMAC, !filtered.contains(where: { $0.mac == selectedMAC }) {
            self.selectedMAC = filtered.first?.mac
        }
        if selectedMAC == nil { selectedMAC = filtered.first?.mac }
        table.reloadData()
        restoreSelection()
        refreshDetail()
    }

    func setSearch(_ text: String) {
        searchText = text
        applyFilter()
        table.reloadData()
        restoreSelection()
    }

    func setPreview(_ samples: [WOLDevice]) {
        previewMode = true
        devices = samples
        selectedMAC = samples.first?.mac
        applyFilter()
        table.reloadData()
        restoreSelection()
        refreshDetail()
    }

    /// 从扫描结果加入一台设备，返回是否新增
    @discardableResult
    func add(host: Host) -> Bool {
        guard let mac = host.mac, WOLService.normalizeMAC(mac) != nil else { return false }
        let normalized = WOLService.normalizeMAC(mac) ?? mac
        let name = host.hostname ?? (host.note.isEmpty ? host.ip : host.note)
        let device = WOLDevice.make(mac: normalized, ip: host.ip, name: name,
                                    vendor: host.vendor,
                                    broadcast: ScanSettings.shared.wolBroadcast,
                                    portMode: ScanSettings.shared.wolPortMode)
        let added = WOLStore.shared.add(device)
        selectedMAC = normalized
        reload()
        onDevicesChanged?()
        return added
    }

    func wake(mac: String) {
        guard let device = devices.first(where: { $0.mac == mac }) else { return }
        selectedMAC = mac
        restoreSelection()
        refreshDetail()
        wake(device: device)
    }

    private func applyFilter() {
        if searchText.isEmpty {
            filtered = devices
        } else {
            let query = searchText.lowercased()
            filtered = devices.filter {
                $0.name.lowercased().contains(query) ||
                $0.ip.lowercased().contains(query) ||
                $0.mac.lowercased().contains(query) ||
                $0.vendor.lowercased().contains(query)
            }
        }
    }

    private func restoreSelection() {
        if let selectedMAC, let index = filtered.firstIndex(where: { $0.mac == selectedMAC }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 64 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HostTableRowView()
        rowView.identifier = Self.rowID
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: self) as? WOLRowView) ?? WOLRowView()
        cell.identifier = Self.cellID
        let device = filtered[row]
        cell.configure(device, selected: tableView.selectedRow == row)
        cell.onWake = { [weak self] in self?.wake(device: $0) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        selectedMAC = filtered[row].mac
        refreshDetail()
    }

    @objc private func tableClicked() {
        let row = table.clickedRow
        guard row >= 0, row < filtered.count else { return }
        selectedMAC = filtered[row].mac
        refreshDetail()
    }

    // MARK: 右侧详情

    private var selectedDevice: WOLDevice? {
        devices.first { $0.mac == selectedMAC }
    }

    private func refreshDetail() {
        guard let device = selectedDevice else {
            deviceTitle.stringValue = "未选择设备"
            deviceSubtitle.stringValue = "先在左侧添加要唤醒的设备"
            macValue.stringValue = "—"
            ipValue.stringValue = "—"
            vendorValue.stringValue = "—"
            wakeInfo.stringValue = ""
            nameEditField.stringValue = ""
            broadcastEditField.stringValue = ""
            nameEditField.isEnabled = false
            broadcastEditField.isEnabled = false
            portDropdown.isEnabled = false
            saveDeviceButton.isEnabled = false
            wakeButton.isEnabled = false
            removeButton.isEnabled = false
            resultLabel.stringValue = ""
            countLabel.stringValue = "\(devices.count) 台设备（显示 \(filtered.count) 台）"
            return
        }

        deviceTitle.stringValue = device.displayName
        deviceSubtitle.stringValue = "\(device.mac)  ·  \(device.ip.isEmpty ? "未记录 IP" : device.ip)"
        macValue.stringValue = device.mac
        ipValue.stringValue = device.ip.isEmpty ? "—" : device.ip
        vendorValue.stringValue = device.vendor.isEmpty ? "—" : device.vendor
        wakeInfo.stringValue = "累计唤醒 \(device.wakeCount) 次  ·  上次 \(device.lastWakeText)"
        nameEditField.stringValue = device.name
        broadcastEditField.stringValue = device.broadcast
        portDropdown.selectedIndex = device.portMode.rawValue
        nameEditField.isEnabled = true
        broadcastEditField.isEnabled = true
        portDropdown.isEnabled = true
        saveDeviceButton.isEnabled = true
        wakeButton.isEnabled = true
        removeButton.isEnabled = true
        resultLabel.stringValue = "目标：\(WOLService.targets(customBroadcast: device.broadcast).joined(separator: "、"))"
        countLabel.stringValue = "\(devices.count) 台设备（显示 \(filtered.count) 台）"
    }

    // MARK: 唤醒

    private func wake(device: WOLDevice) {
        guard let packet = WOLService.makePacket(mac: device.mac) else {
            resultLabel.stringValue = "MAC 地址无效，无法构造唤醒包：\(device.mac)"
            return
        }
        let custom = device.broadcast.isEmpty ? ScanSettings.shared.wolBroadcast : device.broadcast
        let addresses = WOLService.targets(customBroadcast: custom)
        let outcome = WOLService.send(packet: packet, to: addresses,
                                      ports: device.portMode.ports,
                                      repeats: ScanSettings.shared.wolRepeatCount)
        if outcome.succeeded {
            if !previewMode { WOLStore.shared.recordWake(mac: device.mac) }
            if let index = devices.firstIndex(where: { $0.mac == device.mac }) {
                devices[index].lastWokenAt = Date()
                devices[index].wakeCount += 1
            }
            applyFilter()
            table.reloadData()
            restoreSelection()
        }

        var text = outcome.summary
        if !outcome.failures.isEmpty {
            text += "\n失败原因：" + outcome.failures.prefix(2).joined(separator: "；")
        }
        resultLabel.stringValue = text
        onDevicesChanged?()

        if outcome.succeeded, ScanSettings.shared.wolVerifyAfterWake, !device.ip.isEmpty {
            resultLabel.stringValue = text + "\n正在检测设备是否上线…"
            WOLService.verifyReachable(ip: device.ip) { [weak self] online, elapsed in
                guard let self, self.selectedMAC == device.mac else { return }
                let suffix = online
                    ? String(format: "\n✓ 设备已上线（%.1fs 内响应 ping）", elapsed)
                    : "\n· 暂未检测到 ping 响应，设备可能未启用 WOL 或仍在启动"
                self.resultLabel.stringValue = text + suffix
            }
        }
        refreshDetailOnlyStatus()
    }

    /// 刷新累计唤醒次数，但不覆盖结果标签
    private func refreshDetailOnlyStatus() {
        guard let device = selectedDevice else { return }
        wakeInfo.stringValue = "累计唤醒 \(device.wakeCount) 次  ·  上次 \(device.lastWakeText)"
    }

    @objc private func wakeTapped() {
        guard let device = selectedDevice else { return }
        wake(device: device)
    }

    @objc private func wakeAllTapped() {
        guard !devices.isEmpty else { return }
        let settings = ScanSettings.shared
        var totalSent = 0
        var failures: [String] = []
        for device in devices {
            guard let packet = WOLService.makePacket(mac: device.mac) else { continue }
            let custom = device.broadcast.isEmpty ? settings.wolBroadcast : device.broadcast
            let outcome = WOLService.send(packet: packet,
                                          to: WOLService.targets(customBroadcast: custom),
                                          ports: device.portMode.ports,
                                          repeats: settings.wolRepeatCount)
            totalSent += outcome.sent
            failures.append(contentsOf: outcome.failures)
            if outcome.succeeded, !previewMode { WOLStore.shared.recordWake(mac: device.mac) }
        }
        reload()
        resultLabel.stringValue = totalSent > 0
            ? "已向 \(devices.count) 台设备发送 \(totalSent) 个唤醒包" +
              (failures.isEmpty ? "" : "（\(failures.count) 个目标失败）")
            : "全部发送失败：" + (failures.first ?? "未知错误")
    }

    // MARK: 列表操作

    @objc private func addScannedTapped() { onAddScannedSelection?() }

    @objc private func addManualTapped() {
        let alert = NSAlert()
        alert.messageText = "手动添加唤醒设备"
        alert.informativeText = "MAC 地址必填；IP 用于唤醒后检测是否上线，广播地址可选。"
        let name = DarkTextField()
        let mac = DarkTextField()
        let ip = DarkTextField()
        let broadcast = DarkTextField()
        name.placeholderString = "名称，例如：书房 NAS"
        mac.placeholderString = "MAC，例如 50:92:6A:28:7A:4C"
        ip.placeholderString = "IP，例如 192.168.31.20（可选）"
        broadcast.placeholderString = "广播地址（可选）"

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 168))
        stack.orientation = .vertical
        stack.spacing = 6
        for field in [name, mac, ip, broadcast] {
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 312).isActive = true
        }
        alert.accessoryView = stack
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let normalized = WOLService.normalizeMAC(mac.stringValue) else {
            showError("MAC 地址无效", "请填写 6 组十六进制地址，例如 50:92:6A:28:7A:4C。")
            return
        }
        let custom = broadcast.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, ipv4ToUInt32(custom) == nil {
            showError("广播地址无效", "请填写合法的 IPv4 地址，或留空使用自动广播。")
            return
        }
        let ipText = ip.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ipText.isEmpty, ipv4ToUInt32(ipText) == nil {
            showError("IP 地址无效", "请填写合法的 IPv4 地址，或留空。")
            return
        }
        let device = WOLDevice.make(mac: normalized, ip: ipText,
                                    name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                    vendor: OUIVendor.name(for: normalized),
                                    broadcast: custom,
                                    portMode: ScanSettings.shared.wolPortMode)
        if previewMode {
            devices.append(device)
        } else {
            WOLStore.shared.add(device)
        }
        selectedMAC = normalized
        reload()
        onDevicesChanged?()
    }

    @objc private func removeTapped() {
        guard let device = selectedDevice else { return }
        let alert = NSAlert()
        alert.messageText = "从唤醒列表移除「\(device.displayName)」？"
        alert.informativeText = "仅删除本机保存的记录，不会对设备本身做任何操作。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if previewMode {
            devices.removeAll { $0.mac == device.mac }
        } else {
            WOLStore.shared.remove(mac: device.mac)
        }
        selectedMAC = nil
        reload()
        onDevicesChanged?()
    }

    @objc private func saveDeviceTapped() {
        guard var device = selectedDevice else { return }
        let custom = broadcastEditField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, ipv4ToUInt32(custom) == nil {
            showError("广播地址无效", "请填写合法的 IPv4 地址，或留空使用自动广播。")
            return
        }
        device.name = nameEditField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        device.broadcast = custom
        device.portMode = WOLPortMode(rawValue: portDropdown.selectedIndex) ?? .both
        if previewMode {
            if let index = devices.firstIndex(where: { $0.mac == device.mac }) { devices[index] = device }
        } else {
            WOLStore.shared.update(device)
        }
        reload()
        resultLabel.stringValue = "设备信息已保存"
        onDevicesChanged?()
    }

    @objc private func verifyToggled() {
        verifyCheckbox.state = verifyCheckbox.state == .on ? .off : .on
        ScanSettings.shared.wolVerifyAfterWake = verifyCheckbox.state == .on
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - 唤醒页布局

private final class WOLRootView: NSView {
    var listTitle: NSView?
    var countLabel: NSView?
    var addScannedButton: NSView?
    var addManualButton: NSView?
    var wakeAllButton: NSView?
    var removeButton: NSView?
    var scroll: NSScrollView?
    var listHint: NSView?
    var divider: NSView?
    var powerIcon: NSView?
    var deviceTitle: NSView?
    var deviceSubtitle: NSView?
    var macKey: NSView?
    var macValue: NSView?
    var ipKey: NSView?
    var ipValue: NSView?
    var vendorKey: NSView?
    var vendorValue: NSView?
    var wakeInfo: NSView?
    var nameEditLabel: NSView?
    var nameEditField: NSView?
    var broadcastEditLabel: NSView?
    var broadcastEditField: NSView?
    var portEditLabel: NSView?
    var portDropdown: NSView?
    var saveDeviceButton: NSView?
    var editHint: NSView?
    var wakeButton: NSView?
    var resultLabel: NSView?
    var verifyCheckbox: NSView?
    var note1: NSView?
    var note2: NSView?
    var note3: NSView?

    private func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x, y: bounds.height - top - height, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.detail.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let leftWidth: CGFloat = 360
        let rightX = leftWidth + 1
        let rightWidth = max(320, bounds.width - rightX)

        listTitle?.frame = rect(20, 20, leftWidth - 40, 22)
        countLabel?.frame = rect(20, 48, leftWidth - 40, 18)
        addScannedButton?.frame = rect(20, 78, 154, 28)
        addManualButton?.frame = rect(182, 78, 100, 28)
        wakeAllButton?.frame = rect(20, 114, 100, 28)
        removeButton?.frame = rect(128, 114, 76, 28)
        scroll?.frame = NSRect(x: 0, y: 34, width: leftWidth, height: height - 34 - 152)
        listHint?.frame = rect(20, height - 28, leftWidth - 40, 18)
        divider?.frame = NSRect(x: leftWidth, y: 0, width: 1, height: height)
        if let column = (scroll?.documentView as? NSTableView)?.tableColumns.first {
            column.width = leftWidth - 2
        }

        let rx = rightX + 28
        let rw = rightWidth - 56
        powerIcon?.frame = rect(rx, 36, 108, 108)
        deviceTitle?.frame = rect(rx + 128, 52, rw - 128, 38)
        deviceSubtitle?.frame = rect(rx + 128, 94, rw - 128, 20)

        macKey?.frame = rect(rx, 170, 46, 18)
        macValue?.frame = rect(rx + 52, 170, rw - 52, 18)
        ipKey?.frame = rect(rx, 196, 46, 18)
        ipValue?.frame = rect(rx + 52, 196, rw - 52, 18)
        vendorKey?.frame = rect(rx, 222, 46, 18)
        vendorValue?.frame = rect(rx + 52, 222, rw - 52, 18)
        wakeInfo?.frame = rect(rx, 250, rw, 18)

        nameEditLabel?.frame = rect(rx, 292, 100, 18)
        nameEditField?.frame = rect(rx + 104, 289, rw - 104, 24)
        broadcastEditLabel?.frame = rect(rx, 324, 100, 18)
        broadcastEditField?.frame = rect(rx + 104, 321, rw - 104, 24)
        portEditLabel?.frame = rect(rx, 356, 100, 18)
        portDropdown?.frame = rect(rx + 104, 353, rw - 104, 26)
        saveDeviceButton?.frame = rect(rx, 390, 100, 28)
        editHint?.frame = rect(rx + 112, 392, rw - 112, 24)

        wakeButton?.frame = rect(rx, 438, 140, 34)
        verifyCheckbox?.frame = rect(rx + 156, 444, rw - 156, 22)
        resultLabel?.frame = rect(rx, 486, rw, 60)
        note1?.frame = rect(rx, 566, rw, 18)
        note2?.frame = rect(rx, 588, rw, 18)
        note3?.frame = rect(rx, 610, rw, 18)
    }
}

// MARK: - 列表行

private final class WOLRowView: NSTableCellView {
    var onWake: ((WOLDevice) -> Void)?
    private var device: WOLDevice?

    private let iconView = NSImageView()
    private let nameField = Theme.label("", size: 14, weight: .semibold)
    private let macField = Theme.label("", size: 11, color: Theme.secondary)
    private let wakeField = Theme.label("", size: 11, color: Theme.tertiary)
    private let wakeButton = PillButton(title: "唤醒")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.image = Theme.symbol("bolt.fill", size: 22)
        iconView.contentTintColor = Theme.iconBlue
        wakeButton.fillColor = Theme.card
        wakeButton.target = self
        wakeButton.action = #selector(wakeTapped)
        for subview in [iconView, nameField, macField, wakeField, wakeButton] as [NSView] {
            addSubview(subview)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ device: WOLDevice, selected: Bool) {
        self.device = device
        nameField.stringValue = device.displayName
        macField.stringValue = "\(device.mac)  ·  \(device.ip.isEmpty ? "未记录 IP" : device.ip)"
        wakeField.stringValue = "上次 \(device.lastWakeText)  ·  累计 \(device.wakeCount) 次"
        let middle = selected ? NSColor.white.withAlphaComponent(0.88) : Theme.secondary
        let subtle = selected ? NSColor.white.withAlphaComponent(0.72) : Theme.tertiary
        nameField.textColor = .white
        macField.textColor = middle
        wakeField.textColor = subtle
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        iconView.frame = NSRect(x: 14, y: 20, width: 26, height: 26)
        let textX: CGFloat = 50
        let textWidth = width - textX - 78
        nameField.frame = NSRect(x: textX, y: 36, width: textWidth, height: 20)
        macField.frame = NSRect(x: textX, y: 19, width: textWidth, height: 16)
        wakeField.frame = NSRect(x: textX, y: 3, width: textWidth, height: 15)
        wakeButton.frame = NSRect(x: width - 72, y: 20, width: 56, height: 24)
    }

    @objc private func wakeTapped() {
        if let device { onWake?(device) }
    }
}

// MARK: - 电源图标

private final class PowerIconView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(bounds.width, bounds.height) / 100.0
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: scale, y: scale)

        let circle = NSBezierPath(ovalIn: NSRect(x: -38, y: -38, width: 76, height: 76))
        if let gradient = NSGradient(starting: Theme.iconBlueLight, ending: Theme.iconBlue) {
            gradient.draw(in: circle, angle: -70)
        }

        NSColor.white.setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: .zero, radius: 22, startAngle: 130, endAngle: 410, clockwise: false)
        arc.lineWidth = 6
        arc.lineCapStyle = .round
        arc.stroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 0, y: 30))
        stem.line(to: NSPoint(x: 0, y: 2))
        stem.lineWidth = 6
        stem.lineCapStyle = .round
        stem.stroke()
    }
}
