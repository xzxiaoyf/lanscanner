// 生成 DMG 访达窗口背景图（纯 AppKit，无需第三方依赖）
// 用法: swift Support/make_dmg_background.swift /path/to/bg.png
import AppKit

func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, x: CGFloat, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("用法: make_dmg_background.swift <输出.png>\n".data(using: .utf8)!)
    exit(2)
}

let out = CommandLine.arguments[1]
let canvas = NSSize(width: 760, height: 480)
let image = NSImage(size: canvas)
image.lockFocus()

let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.075, green: 0.10, blue: 0.15, alpha: 1),
    ending: NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.29, alpha: 1))
gradient?.draw(in: NSRect(origin: .zero, size: canvas), angle: -55)

NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.96, alpha: 1).setFill()
NSRect(x: 0, y: canvas.height - 5, width: canvas.width, height: 5).fill()

drawText("LANScanner", size: 34, weight: .bold, color: .white, x: 38, y: 414)
drawText("局域网设备与端口扫描   ·   Universal (Intel + Apple Silicon)",
         size: 14, weight: .regular,
         color: NSColor(calibratedWhite: 0.72, alpha: 1), x: 40, y: 388)

// 中间的拖拽指示箭头
let arrow = NSColor(calibratedRed: 0.36, green: 0.66, blue: 1.0, alpha: 0.95)
arrow.setStroke()
arrow.setFill()
let line = NSBezierPath()
line.move(to: NSPoint(x: 258, y: 248))
line.line(to: NSPoint(x: 494, y: 248))
line.lineWidth = 5
line.lineCapStyle = .round
line.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 492, y: 264))
head.line(to: NSPoint(x: 516, y: 248))
head.line(to: NSPoint(x: 492, y: 232))
head.close()
head.fill()

drawText("拖到 Applications 安装", size: 16, weight: .medium,
         color: .white, x: 268, y: 108)
drawText("macOS 11.0 或更高版本   ·   首次打开受阻请见「安装说明.txt」",
         size: 12, weight: .regular,
         color: NSColor(calibratedWhite: 0.62, alpha: 1), x: 190, y: 82)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("背景图生成失败\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
print("背景图: \(out)")
