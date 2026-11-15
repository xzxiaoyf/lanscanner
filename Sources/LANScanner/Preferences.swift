import AppKit

/// 顶部齿轮按钮弹出的扫描设置
final class PreferencesViewController: NSViewController {
    var onApply: (() -> Void)?
    var onPickNetwork: (() -> Void)?
    private var networkOptions: [LocalNetwork] = []

    private let titleLabel = Theme.label("扫描设置", size: 15, weight: .semibold)
    private let pingLabel = Theme.label("Ping 超时 (ms)", size: 12, color: Theme.secondary)
    private let portTimeoutLabel = Theme.label("端口连接超时 (ms)", size: 12, color: Theme.secondary)
    private let concurrencyLabel = Theme.label("Ping 并发数", size: 12, color: Theme.secondary)
    private let presetLabel = Theme.label("端口范围", size: 12, color: Theme.secondary)
    private let customLabel = Theme.label("自定义端口", size: 12, color: Theme.secondary)

    private let pingField = DarkTextField()
    private let portTimeoutField = DarkTextField()
    private let concurrencyField = DarkTextField()
    private let customField = DarkTextField()
    private let presetDropdown = DropdownButton(options: PortPreset.allCases.map { $0.title })
    private let hintLabel = Theme.label("自定义格式：80,443,8000-8100", size: 11, color: Theme.tertiary)
    private let saveButton = PillButton(title: "保存")
    private let resetButton = PillButton(title: "恢复默认")
    private let networkLabel = Theme.label("扫描网络：", size: 12, color: Theme.secondary)
    private let networkDropdown = DropdownButton(options: ["自动（默认路由接口）"])
    private let pickerCheckbox = CheckToggle(title: "每次扫描前显示网络选择窗口")
    private let currentNetworkLabel = Theme.label("", size: 11, color: Theme.secondary)
    private let pickNetworkButton = PillButton(title: "选择网络…")
    private let sectionSeparator = Theme.hairline(.zero)

    private let wolSectionLabel = Theme.label("网络唤醒 (WOL)", size: 13, weight: .semibold)
    private let wolPortLabel = Theme.label("唤醒端口", size: 12, color: Theme.secondary)
    private let wolPortDropdown = DropdownButton(options: WOLPortMode.optionTitles)
    private let wolBroadcastLabel = Theme.label("广播地址（可选）", size: 12, color: Theme.secondary)
    private let wolBroadcastField = DarkTextField()
    private let wolRepeatLabel = Theme.label("重复次数", size: 12, color: Theme.secondary)
    private let wolRepeatDropdown = DropdownButton(options: ["发送 1 次", "发送 2 次", "发送 3 次"])
    private let wolVerifyCheckbox = CheckToggle(title: "唤醒后 ping 检测设备是否上线")
    private let wolHintLabel = Theme.label("设备需支持并启用 WoL；Magic Packet 无确认机制，发送成功不代表设备已开机。",
                                           size: 11, color: Theme.tertiary)

    override func loadView() {
        let root = PreferencesRootView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.window.cgColor
        view = root

        customField.placeholderString = "80,443,8000-8100"
        wolBroadcastField.placeholderString = "留空则自动使用子网广播"
        wolHintLabel.lineBreakMode = .byWordWrapping
        wolHintLabel.maximumNumberOfLines = 2
        wolHintLabel.cell?.wraps = true
        wolHintLabel.cell?.isScrollable = false
        wolVerifyCheckbox.target = self
        wolVerifyCheckbox.action = #selector(wolVerifyToggled)

        networkOptions = LocalNetwork.all()
        networkDropdown.options = ["自动（默认路由接口）"] + networkOptions.map {
            "\($0.displayName)  ·  \($0.isActive ? $0.ip : "未连接")"
        }
        networkDropdown.onSelect = { [weak self] index in
            guard let self else { return }
            let settings = ScanSettings.shared
            if index == 0 || index - 1 >= self.networkOptions.count {
                settings.selectedInterface = ""
            } else {
                settings.selectedInterface = self.networkOptions[index - 1].interface
            }
            self.refreshCurrentNetwork()
        }
        presetDropdown.onSelect = { [weak self] _ in self?.updateCustomState() }

        pickerCheckbox.target = self
        pickerCheckbox.action = #selector(pickerCheckboxChanged)
        pickNetworkButton.target = self
        pickNetworkButton.action = #selector(pickNetworkTapped)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.isChosen = true
        resetButton.target = self
        resetButton.action = #selector(resetTapped)

        for subview in [titleLabel, pingLabel, portTimeoutLabel, concurrencyLabel,
                        presetLabel, customLabel, pingField, portTimeoutField,
                        concurrencyField, customField, presetDropdown, hintLabel,
                        saveButton, resetButton, networkLabel, networkDropdown,
                        pickerCheckbox, pickNetworkButton, sectionSeparator,
                        currentNetworkLabel, wolSectionLabel, wolPortLabel, wolPortDropdown,
                        wolBroadcastLabel, wolBroadcastField, wolRepeatLabel, wolRepeatDropdown,
                        wolVerifyCheckbox, wolHintLabel] as [NSView] {
            root.addSubview(subview)
        }
        root.titleLabel = titleLabel
        root.pingLabel = pingLabel
        root.portTimeoutLabel = portTimeoutLabel
        root.concurrencyLabel = concurrencyLabel
        root.presetLabel = presetLabel
        root.customLabel = customLabel
        root.pingField = pingField
        root.portTimeoutField = portTimeoutField
        root.concurrencyField = concurrencyField
        root.customField = customField
        root.presetDropdown = presetDropdown
        root.hintLabel = hintLabel
        root.saveButton = saveButton
        root.resetButton = resetButton
        root.networkLabel = networkLabel
        root.networkDropdown = networkDropdown
        root.pickerCheckbox = pickerCheckbox
        root.pickNetworkButton = pickNetworkButton
        root.sectionSeparator = sectionSeparator
        root.currentNetworkLabel = currentNetworkLabel
        root.wolSectionLabel = wolSectionLabel
        root.wolPortLabel = wolPortLabel
        root.wolPortDropdown = wolPortDropdown
        root.wolBroadcastLabel = wolBroadcastLabel
        root.wolBroadcastField = wolBroadcastField
        root.wolRepeatLabel = wolRepeatLabel
        root.wolRepeatDropdown = wolRepeatDropdown
        root.wolVerifyCheckbox = wolVerifyCheckbox
        root.wolHintLabel = wolHintLabel

        loadValues()
    }

    private func loadValues() {
        let settings = ScanSettings.shared
        pingField.stringValue = "\(settings.pingTimeoutMs)"
        portTimeoutField.stringValue = "\(settings.portTimeoutMs)"
        concurrencyField.stringValue = "\(settings.pingConcurrency)"
        customField.stringValue = settings.customPorts
        presetDropdown.selectedIndex = settings.portPreset.rawValue
        if settings.selectedInterface.isEmpty {
            networkDropdown.selectedIndex = 0
        } else if let index = networkOptions.firstIndex(where: { $0.interface == settings.selectedInterface }) {
            networkDropdown.selectedIndex = index + 1
        } else {
            networkDropdown.selectedIndex = 0
        }
        pickerCheckbox.state = settings.showNetworkPicker ? .on : .off
        wolPortDropdown.selectedIndex = settings.wolPortMode.rawValue
        wolBroadcastField.stringValue = settings.wolBroadcast
        wolRepeatDropdown.selectedIndex = Swift.min(Swift.max(settings.wolRepeatCount - 1, 0), 2)
        wolVerifyCheckbox.state = settings.wolVerifyAfterWake ? .on : .off
        refreshCurrentNetwork()
        updateCustomState()
    }

    private func refreshCurrentNetwork() {
        if let network = LocalNetwork.current() {
            currentNetworkLabel.stringValue = "当前扫描范围：\(network.scanLabel)"
        } else {
            currentNetworkLabel.stringValue = "当前扫描范围：未连接"
        }
    }

    private func updateCustomState() {
        let isCustom = presetDropdown.selectedIndex == PortPreset.custom.rawValue
        customField.isEnabled = isCustom
        hintLabel.isHidden = !isCustom
    }

    @objc private func pickerCheckboxChanged() {
        pickerCheckbox.state = pickerCheckbox.state == .on ? .off : .on
        ScanSettings.shared.showNetworkPicker = pickerCheckbox.state == .on
    }

    @objc private func wolVerifyToggled() {
        wolVerifyCheckbox.state = wolVerifyCheckbox.state == .on ? .off : .on
        ScanSettings.shared.wolVerifyAfterWake = wolVerifyCheckbox.state == .on
    }

    @objc private func pickNetworkTapped() { onPickNetwork?() }

    @objc private func saveTapped() {
        let settings = ScanSettings.shared
        settings.pingTimeoutMs = Int(pingField.stringValue) ?? 400
        settings.portTimeoutMs = Int(portTimeoutField.stringValue) ?? 400
        settings.pingConcurrency = Int(concurrencyField.stringValue) ?? 48
        settings.portPreset = PortPreset(rawValue: presetDropdown.selectedIndex) ?? .common
        settings.customPorts = customField.stringValue

        let broadcast = wolBroadcastField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !broadcast.isEmpty, ipv4ToUInt32(broadcast) == nil {
            let alert = NSAlert()
            alert.messageText = "广播地址无效"
            alert.informativeText = "请填写合法的 IPv4 地址（例如 192.168.31.255），或留空使用自动广播。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        settings.wolPortMode = WOLPortMode(rawValue: wolPortDropdown.selectedIndex) ?? .both
        settings.wolBroadcast = broadcast
        settings.wolRepeatCount = wolRepeatDropdown.selectedIndex + 1
        settings.wolVerifyAfterWake = wolVerifyCheckbox.state == .on
        onApply?()
    }

    @objc private func resetTapped() {
        ScanSettings.shared.reset()
        loadValues()
    }
}

private final class PreferencesRootView: NSView {
    var titleLabel: NSView?
    var pingLabel: NSView?
    var portTimeoutLabel: NSView?
    var concurrencyLabel: NSView?
    var presetLabel: NSView?
    var customLabel: NSView?
    var pingField: NSView?
    var portTimeoutField: NSView?
    var concurrencyField: NSView?
    var customField: NSView?
    var presetDropdown: NSView?
    var hintLabel: NSView?
    var saveButton: NSView?
    var resetButton: NSView?
    var networkLabel: NSView?
    var networkDropdown: NSView?
    var pickerCheckbox: NSView?
    var pickNetworkButton: NSView?
    var sectionSeparator: NSView?
    var currentNetworkLabel: NSView?
    var wolSectionLabel: NSView?
    var wolPortLabel: NSView?
    var wolPortDropdown: NSView?
    var wolBroadcastLabel: NSView?
    var wolBroadcastField: NSView?
    var wolRepeatLabel: NSView?
    var wolRepeatDropdown: NSView?
    var wolVerifyCheckbox: NSView?
    var wolHintLabel: NSView?

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
        let labelWidth: CGFloat = 150
        let fieldX: CGFloat = 174
        let fieldWidth = width - fieldX - 22

        titleLabel?.frame = rect(20, 18, width - 40, 22)
        pingLabel?.frame = rect(20, 56, labelWidth, 20)
        pingField?.frame = rect(fieldX, 54, fieldWidth, 24)
        portTimeoutLabel?.frame = rect(20, 88, labelWidth, 20)
        portTimeoutField?.frame = rect(fieldX, 86, fieldWidth, 24)
        concurrencyLabel?.frame = rect(20, 120, labelWidth, 20)
        concurrencyField?.frame = rect(fieldX, 118, fieldWidth, 24)
        presetLabel?.frame = rect(20, 152, labelWidth, 20)
        presetDropdown?.frame = rect(fieldX, 150, fieldWidth, 26)
        customLabel?.frame = rect(20, 184, labelWidth, 20)
        customField?.frame = rect(fieldX, 182, fieldWidth, 24)
        hintLabel?.frame = rect(fieldX, 208, fieldWidth, 16)
        networkLabel?.frame = rect(20, 240, 90, 20)
        networkDropdown?.frame = rect(110, 238, width - 130, 26)
        pickerCheckbox?.frame = rect(20, 272, width - 40, 20)
        pickNetworkButton?.frame = rect(20, 300, 140, 28)
        currentNetworkLabel?.frame = rect(20, 332, width - 40, 16)
        sectionSeparator?.frame = rect(20, 352, width - 40, 1)
        wolSectionLabel?.frame = rect(20, 360, width - 40, 20)
        let wolFieldX: CGFloat = 112
        let wolFieldWidth = width - wolFieldX - 22
        wolPortLabel?.frame = rect(20, 388, 88, 20)
        wolPortDropdown?.frame = rect(wolFieldX, 386, wolFieldWidth, 26)
        wolBroadcastLabel?.frame = rect(20, 420, 88, 20)
        wolBroadcastField?.frame = rect(wolFieldX, 418, wolFieldWidth, 24)
        wolRepeatLabel?.frame = rect(20, 450, 88, 20)
        wolRepeatDropdown?.frame = rect(wolFieldX, 448, wolFieldWidth, 26)
        wolVerifyCheckbox?.frame = rect(20, 480, width - 40, 20)
        wolHintLabel?.frame = rect(20, 506, width - 40, 30)
        resetButton?.frame = rect(20, 544, 90, 28)
        saveButton?.frame = rect(width - 102, 544, 82, 28)
    }
}
