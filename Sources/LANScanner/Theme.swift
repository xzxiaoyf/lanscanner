import AppKit

// MARK: - 配色（参照 inet network scanner 深色界面）

enum Theme {
    static let window = NSColor(srgbRed: 0.105, green: 0.108, blue: 0.118, alpha: 1)
    static let titleBar = NSColor(srgbRed: 0.088, green: 0.091, blue: 0.100, alpha: 1)
    static let sidebar = NSColor(srgbRed: 0.093, green: 0.096, blue: 0.105, alpha: 1)
    static let list = NSColor(srgbRed: 0.118, green: 0.121, blue: 0.132, alpha: 1)
    static let detail = NSColor(srgbRed: 0.128, green: 0.131, blue: 0.142, alpha: 1)
    static let card = NSColor(srgbRed: 0.175, green: 0.180, blue: 0.194, alpha: 1)
    static let divider = NSColor(srgbRed: 0.215, green: 0.220, blue: 0.235, alpha: 1)
    static let accent = NSColor(srgbRed: 0.086, green: 0.416, blue: 0.902, alpha: 1)
    static let button = NSColor(srgbRed: 0.205, green: 0.210, blue: 0.225, alpha: 1)
    static let segment = NSColor(srgbRed: 0.163, green: 0.168, blue: 0.182, alpha: 1)
    static let text = NSColor(srgbRed: 0.965, green: 0.970, blue: 0.980, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.665, green: 0.680, blue: 0.710, alpha: 1)
    static let tertiary = NSColor(srgbRed: 0.450, green: 0.465, blue: 0.495, alpha: 1)
    static let green = NSColor(srgbRed: 0.240, green: 0.790, blue: 0.420, alpha: 1)
    static let amber = NSColor(srgbRed: 0.930, green: 0.690, blue: 0.230, alpha: 1)
    static let iconBlue = NSColor(srgbRed: 0.290, green: 0.640, blue: 0.950, alpha: 1)
    static let iconBlueLight = NSColor(srgbRed: 0.620, green: 0.850, blue: 1.0, alpha: 1)

    static func label(_ text: String,
                      size: CGFloat,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = Theme.text) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.drawsBackground = false
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func monospaceLabel(_ text: String, size: CGFloat, color: NSColor = Theme.text) -> NSTextField {
        let field = label(text, size: size, color: color)
        field.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return field
    }

    /// 返回模板化的 SF Symbol，颜色由承载控件的 contentTintColor 决定
    /// （直接对绘制结果做 sourceAtop 填充会把整个矩形染成色块）
    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let image = base.withSymbolConfiguration(configuration) ?? base
        image.isTemplate = true
        return image
    }

    static func hairline(_ frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = divider.cgColor
        return view
    }
}

// MARK: - 纯色背景视图（用 draw 绘制，离屏渲染 / PDF 同样可见）

final class SolidView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    convenience init(color: NSColor, cornerRadius: CGFloat = 0) {
        self.init(frame: .zero)
        self.color = color
        self.cornerRadius = cornerRadius
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        if cornerRadius > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        } else {
            NSBezierPath(rect: bounds).fill()
        }
    }
}

final class DotView: NSView {
    var color: NSColor = Theme.green { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - 扁平按钮 / 分段控件

class PillButton: NSButton {
    var fillColor: NSColor = Theme.button { didSet { needsDisplay = true } }
    var isChosen: Bool = false { didSet { needsDisplay = true } }
    var titleColor: NSColor = Theme.text {
        didSet { refreshTitle() }
    }

    convenience init(title: String, image: NSImage? = nil) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        self.imagePosition = image == nil ? .noImage : .imageLeading
        self.isBordered = false
        self.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        refreshTitle()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshTitle() {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: titleColor,
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    override var title: String {
        didSet { refreshTitle() }
    }

    override func draw(_ dirtyRect: NSRect) {
        var color = isChosen ? Theme.accent : fillColor
        if isHighlighted {
            color = color.blended(withFraction: 0.16, of: .white) ?? color
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}

final class IconButton: NSButton {
    var isChosen: Bool = false { didSet { needsDisplay = true } }
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }

    convenience init(symbol: String, size: CGFloat = 16, color: NSColor = Theme.secondary) {
        self.init(frame: .zero)
        image = Theme.symbol(symbol, size: size)
        contentTintColor = color
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen || fillColor.alphaComponent > 0 {
            (isChosen ? Theme.card : fillColor).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        if isHighlighted {
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 自绘下拉按钮（避免系统 NSPopUpButton 在离屏渲染中不可见）
final class DropdownButton: PillButton {
    var options: [String] = [] { didSet { updateTitle() } }
    var selectedIndex: Int = 0 { didSet { updateTitle() } }
    var onSelect: ((Int) -> Void)?

    convenience init(options: [String]) {
        self.init(title: "")
        self.options = options
        self.target = self
        self.action = #selector(openMenu)
        updateTitle()
    }

    private func updateTitle() {
        guard options.indices.contains(selectedIndex) else { return }
        title = options[selectedIndex] + "  ▾"
    }

    @objc private func openMenu() {
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }
}

/// 自绘深色输入框：不依赖系统 bezel，深色外观与离屏渲染表现一致
final class DarkTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        textColor = Theme.text
        font = NSFont.systemFont(ofSize: 12)
        alignment = .left
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.card.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        super.draw(dirtyRect)
    }
}

/// 自绘复选框：避免系统 NSButtonCell 在离屏渲染中不绘制。
/// 同时完全接管点击：默认 NSButton 是「瞬时按钮」，NSButtonCell 会在鼠标抬起时
/// 把 state 复位为 off；再叠加各界面 action 里的手动翻转，勾选状态会被覆盖，
/// 且手动改 state 不会触发本类自绘内容的重绘，表现为「复选框点不动」。
final class CheckToggle: NSButton {
    convenience init(title: String) {
        self.init(frame: .zero)
        self.title = title
        isBordered = false
        setOn(false)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        state = .off
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 诊断用：记录显式请求自绘重绘的次数（NSView.needsDisplay 在离屏视图上不可靠）
    private(set) var redrawCount = 0

    /// 统一入口：写入状态并确保自绘内容刷新
    func setOn(_ on: Bool) {
        state = on ? .on : .off
        needsDisplay = true
        redrawCount += 1
    }

    /// 鼠标、键盘、自检共用的切换逻辑：只翻转一次，并派发 target/action
    func toggle() {
        guard isEnabled else { return }
        setOn(state != .on)
        guard let action = action else { return }
        if !NSApplication.shared.sendAction(action, to: target, from: self),
           let object = target as? NSObject {
            _ = object.perform(action, with: self)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 不调用 super：避免 NSButtonCell 的瞬时状态机复位 state
        toggle()
    }

    override func mouseUp(with event: NSEvent) {
        // 由 mouseDown 完整处理；调用 super 会把刚设置的状态改回 off
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        if key == " " || key == "\r" {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 16
        let box = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        (state == .on ? Theme.accent : Theme.card).setFill()
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        boxPath.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        boxPath.lineWidth = 1
        boxPath.stroke()
        if state == .on {
            NSColor.white.setStroke()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 4, y: box.midY))
            check.line(to: NSPoint(x: 7.5, y: box.midY - 3.5))
            check.line(to: NSPoint(x: 12.5, y: box.midY + 4))
            check.lineWidth = 2.2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.text,
            .font: NSFont.systemFont(ofSize: 12)
        ]
        (title as NSString).draw(at: NSPoint(x: 24, y: (bounds.height - 16) / 2),
                                 withAttributes: attributes)
    }
}

/// 自绘分段控件：选中段为蓝色圆角，未选中为深灰
final class SegmentedTabs: NSView {
    var onSelect: ((Int) -> Void)?
    private(set) var buttons: [PillButton] = []

    var selectedIndex: Int = 0 {
        didSet { updateSelection() }
    }

    convenience init(titles: [String]) {
        self.init(frame: .zero)
        for (index, title) in titles.enumerated() {
            let button = PillButton(title: title)
            button.fillColor = Theme.segment
            button.target = self
            button.action = #selector(segmentTapped(_:))
            button.tag = index
            button.titleColor = Theme.secondary
            addSubview(button)
            buttons.append(button)
        }
        updateSelection()
    }

    @objc private func segmentTapped(_ sender: PillButton) {
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            button.isChosen = index == selectedIndex
            button.titleColor = index == selectedIndex ? .white : Theme.secondary
        }
    }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: bounds.minX + CGFloat(index) * (width + gap),
                                  y: bounds.minY, width: width, height: bounds.height)
        }
    }
}

// MARK: - 自绘图标

/// 参照截图右侧的地球（经纬线 + 底座）图标
final class GlobeIconView: NSView {
    var strokeColor: NSColor = Theme.text

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(bounds.width, bounds.height) / 100.0
        context.translateBy(x: bounds.midX, y: bounds.midY + 2 * scale)
        context.scaleBy(x: scale, y: scale)

        strokeColor.setStroke()
        strokeColor.setFill()

        let circle = NSBezierPath(ovalIn: NSRect(x: -36, y: -36, width: 72, height: 72))
        circle.lineWidth = 5
        circle.stroke()

        // 经线：两条竖向椭圆
        let meridian = NSBezierPath(ovalIn: NSRect(x: -16, y: -36, width: 32, height: 72))
        meridian.lineWidth = 3.6
        meridian.stroke()

        // 纬线：裁切在地球圆内
        context.saveGState()
        circle.setClip()
        for y in [-18.0, 0.0, 18.0] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: -38, y: y))
            line.line(to: NSPoint(x: 38, y: y))
            line.lineWidth = 3.6
            line.stroke()
        }
        let equator = NSBezierPath(ovalIn: NSRect(x: -36, y: -9, width: 72, height: 18))
        equator.lineWidth = 3.6
        equator.stroke()
        context.restoreGState()

        // 左侧白色月牙，模拟截图中的立体高光
        let crescent = NSBezierPath()
        crescent.appendArc(withCenter: NSPoint(x: -5, y: 0), radius: 36,
                           startAngle: 118, endAngle: 242, clockwise: false)
        crescent.lineWidth = 6
        crescent.stroke()

        // 底座：— ● —
        let left = NSBezierPath()
        left.move(to: NSPoint(x: -38, y: -45))
        left.line(to: NSPoint(x: -8, y: -45))
        left.lineWidth = 6
        left.lineCapStyle = .round
        left.stroke()

        let right = NSBezierPath()
        right.move(to: NSPoint(x: 8, y: -45))
        right.line(to: NSPoint(x: 38, y: -45))
        right.lineWidth = 6
        right.lineCapStyle = .round
        right.stroke()

        NSBezierPath(ovalIn: NSRect(x: -6, y: -51, width: 12, height: 12)).fill()
    }
}

/// 列表行图标：网关为地球，普通主机为蓝色显示器
final class DeviceIconView: NSView {
    enum Mode { case gateway, host }

    var mode: Mode = .host { didSet { rebuild() } }
    private var globe: GlobeIconView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuild() {
        globe?.removeFromSuperview()
        globe = nil
        if mode == .gateway {
            let view = GlobeIconView(frame: bounds)
            view.strokeColor = Theme.text
            addSubview(view)
            globe = view
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        globe?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard mode == .host, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(bounds.width, bounds.height) / 100.0
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: scale, y: scale)

        let screenRect = NSRect(x: -34, y: -2, width: 68, height: 52)
        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 5, yRadius: 5)
        if let gradient = NSGradient(starting: Theme.iconBlueLight, ending: Theme.iconBlue) {
            gradient.draw(in: screenPath, angle: -70)
        }
        Theme.iconBlue.setStroke()
        screenPath.lineWidth = 2
        screenPath.stroke()

        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: -28, y: 30, width: 56, height: 10),
                     xRadius: 4, yRadius: 4).fill()

        NSColor(srgbRed: 0.42, green: 0.48, blue: 0.56, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: -9, y: -12, width: 18, height: 12),
                     xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: NSRect(x: -22, y: -17, width: 44, height: 6),
                     xRadius: 3, yRadius: 3).fill()
    }
}

/// "未发现服务" 占位图标：菱形 + 循环箭头
final class CycleIconView: NSView {
    var strokeColor: NSColor = Theme.tertiary

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(bounds.width, bounds.height) / 100.0
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: scale, y: scale)
        strokeColor.setStroke()
        strokeColor.setFill()

        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: 0, y: 49))
        diamond.line(to: NSPoint(x: 49, y: 0))
        diamond.line(to: NSPoint(x: 0, y: -49))
        diamond.line(to: NSPoint(x: -49, y: 0))
        diamond.close()
        diamond.lineWidth = 4
        diamond.lineJoinStyle = .round
        diamond.stroke()

        let topArc = NSBezierPath()
        topArc.appendArc(withCenter: .zero, radius: 21, startAngle: 35, endAngle: 175, clockwise: false)
        topArc.lineWidth = 5
        topArc.lineCapStyle = .round
        topArc.stroke()
        let bottomArc = NSBezierPath()
        bottomArc.appendArc(withCenter: .zero, radius: 21, startAngle: 215, endAngle: 355, clockwise: false)
        bottomArc.lineWidth = 5
        bottomArc.lineCapStyle = .round
        bottomArc.stroke()

        // 箭头
        for angle in [35.0, 215.0] {
            let radians = angle * .pi / 180
            let tip = NSPoint(x: cos(radians) * 21, y: sin(radians) * 21)
            let tangent = angle == 35 ? radians - .pi / 2 : radians + .pi / 2
            let arrow = NSBezierPath()
            arrow.move(to: tip)
            arrow.line(to: NSPoint(x: tip.x + cos(tangent + 0.55) * 11,
                                   y: tip.y + sin(tangent + 0.55) * 11))
            arrow.line(to: NSPoint(x: tip.x + cos(tangent - 0.55) * 11,
                                   y: tip.y + sin(tangent - 0.55) * 11))
            arrow.close()
            arrow.fill()
        }
    }
}
