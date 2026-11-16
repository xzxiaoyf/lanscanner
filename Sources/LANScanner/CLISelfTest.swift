import Foundation
import Darwin
import AppKit

/// 用于验证复选框 action 是否按预期派发
private final class CheckboxProbe: NSObject {
    var fireCount = 0
    var lastState: NSControl.StateValue = .off
    @objc func changed(_ sender: CheckToggle) {
        fireCount += 1
        lastState = sender.state
    }
}

/// 无界面自检，便于在终端验证核心能力：
///   LANScanner --selftest
enum CLISelfTest {
    static func start() {
        print("=== LANScanner 自检 ===")
        guard let network = LocalNetwork.detect() else {
            print("[FAIL] 未能识别本机 IPv4 网段")
            exit(1)
        }
        print("网卡: \(network.interface)")
        print("本机: \(network.ip)  网段: \(network.cidr)")
        print("网关: \(network.gateway ?? "未识别")  待探测地址: \(network.hostIPs.count) 个")

        // 单元校验：MAC 归一化 / RTT 解析 / ARP 解析 / 端口范围解析
        assert(OUIVendor.normalize("7c:c2:94:a:a9:a7") == "7C:C2:94:0A:A9:A7", "MAC 归一化失败")
        assert(OUIVendor.name(for: "8A:36:A4:18:CB:0B") == "私人 MAC 地址", "本地管理地址判定失败")
        assert(abs((LANScanner.parseRTT("round-trip min/avg/max/stddev = 1.0/2.5/3.0/0.0 ms") ?? 0) - 2.5) < 0.001, "RTT 解析失败")
        assert(PortLists.parse("80,443,8000-8002") == [80, 443, 8000, 8001, 8002], "端口范围解析失败")
        let arpSample = "xiaoqiang (192.168.31.1) at 50:92:6a:28:7a:4c on en2 ifscope [ethernet]\n" +
                        "? (192.168.31.27) at 8a:36:a4:18:cb:b on en2 ifscope [ethernet]"
        assert(LANScanner.parseARP(arpSample)["192.168.31.27"]?.mac == "8A:36:A4:18:CB:0B", "ARP 解析失败")
        assert(LANScanner.parseARP(arpSample)["192.168.31.1"]?.hostname == "xiaoqiang", "ARP 名称解析失败")
        assert(MACAddress.normalize("50-92-6a-28-7a-4c") == "50:92:6A:28:7A:4C", "连字符 MAC 解析失败")
        assert(MACAddress.normalize("5092.6a28.7a4c") == "50:92:6A:28:7A:4C", "点分 MAC 解析失败")
        assert(MACAddress.normalize("50926A287A4C") == "50:92:6A:28:7A:4C", "连续 12 位 MAC 解析失败")
        let incomplete = "? (192.168.31.99) at (incomplete) on en0 ifscope [ethernet]"
        assert(LANScanner.parseARP(incomplete)["192.168.31.99"]?.mac == nil, "incomplete 不应产生 MAC")
        let routeSample = "192.168.31.1   50:92:6a:28:7a:4c   UHLWIir   en2   1193\n" +
                          "192.168.31      link#7                UCS       en2      !"
        assert(ARPCache.parseNetstatRoutes(routeSample)["192.168.31.1"]?.mac == "50:92:6A:28:7A:4C", "netstat 路由解析失败")
        assert(OUIVendor.name(for: "E4:AA:EC:60:35:D3") == "Tianjin Hualai Technology Co., Ltd", "OUI 厂商解析失败")
        assert(OUIVendor.name(for: "00:0F:68:54:8A:C4") == "Vavic Network Technology", "外部 OUI 库未生效")
        assert(OUIVendor.databaseCount > 50_000, "完整 OUI 数据库未加载")
        assert(OUIEmbedded.text.utf8.count > 1_000_000, "内嵌 OUI 副本缺失")
        print("[OK] 解析器单元校验通过")
        print("[OK] OUI 数据库: \(OUIVendor.sourceDescription)（内嵌副本 \(OUIEmbedded.text.utf8.count) 字节可用）")

        // 复选框：验证点击后状态保持、action 派发与自绘重绘（1.1.4 修复项）
        let probe = CheckboxProbe()
        let toggle = CheckToggle(title: "自检")
        toggle.target = probe
        toggle.action = #selector(CheckboxProbe.changed(_:))
        let baseline = toggle.redrawCount
        toggle.setOn(false)
        toggle.toggle()
        let firstOn = toggle.state == .on && probe.fireCount == 1 && probe.lastState == .on
        toggle.toggle()
        let secondOff = toggle.state == .off && probe.fireCount == 2 && probe.lastState == .off
        let redraws = toggle.redrawCount - baseline
        print(firstOn && secondOff && redraws == 3
              ? "[OK] 复选框：off → on → off，action 各派发 1 次，显式重绘 \(redraws) 次"
              : "[FAIL] 复选框状态切换异常 firstOn=\(firstOn) secondOff=\(secondOff) " +
                "state=\(toggle.state.rawValue) action=\(probe.fireCount) redraw=\(redraws)")

        // 事件链路：布局命中 → mouseDown → action → mouseUp。
        // 命令行进程没有 GUI run loop，NSWindow.sendEvent 不会派发，故直接对控件投递事件。
        let clickWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        let clickRoot = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        clickWindow.contentView = clickRoot
        let clickToggle = CheckToggle(title: "点击事件测试")
        clickToggle.frame = NSRect(x: 20, y: 30, width: 200, height: 22)
        let clickProbe = CheckboxProbe()
        clickToggle.target = clickProbe
        clickToggle.action = #selector(CheckboxProbe.changed(_:))
        clickRoot.addSubview(clickToggle)
        let clickPoint = NSPoint(x: 28, y: 41)
        // 方框与文字标签都应落在可点击区域内
        let hitOK = clickRoot.hitTest(clickPoint) === clickToggle &&
                    clickRoot.hitTest(NSPoint(x: 120, y: 41)) === clickToggle
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint,
                                         modifierFlags: [], timestamp: 0,
                                         windowNumber: clickWindow.windowNumber,
                                         context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
            clickToggle.mouseDown(with: down)
        }
        let afterDown = clickToggle.state
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: clickPoint,
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: clickWindow.windowNumber,
                                       context: nil, eventNumber: 2, clickCount: 1, pressure: 0) {
            clickToggle.mouseUp(with: up)
        }
        let clickOK = afterDown == .on && clickToggle.state == .on && clickProbe.fireCount == 1
        print(clickOK && hitOK
              ? "[OK] 复选框点击事件：方框与文字均命中 → mouseDown 派发 action，mouseUp 未复位状态"
              : "[FAIL] 点击事件链路异常 hit=\(hitOK) afterDown=\(afterDown.rawValue) " +
                "final=\(clickToggle.state.rawValue) action=\(clickProbe.fireCount)")

        // WOL：Magic Packet 结构 / MAC 格式兼容 / 持久化 / 真实 UDP 广播
        let wolPacket = WOLService.makePacket(mac: "50:92:6A:28:7A:4C")
        assert(wolPacket?.count == 102, "Magic Packet 长度应为 102 字节")
        let expectedMAC: [UInt8] = [0x50, 0x92, 0x6A, 0x28, 0x7A, 0x4C]
        if let wolPacket {
            assert(Array(wolPacket.prefix(6)) == [UInt8](repeating: 0xFF, count: 6), "前导 6 字节错误")
            assert(Array(wolPacket[6..<12]) == expectedMAC, "MAC 段错误")
            assert(Array(wolPacket[96..<102]) == expectedMAC, "MAC 重复 16 次错误")
        }
        assert(WOLService.normalizeMAC("50-92-6a-28-7a-4c") == "50:92:6A:28:7A:4C", "MAC 分隔格式解析失败")
        assert(WOLService.normalizeMAC("7c:c2:94:a:a9:a7") == "7C:C2:94:0A:A9:A7", "省略前导零 MAC 解析失败")

        let tempStoreURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lanscanner-wol-selftest-\(UUID().uuidString).json")
        let testStore = WOLStore(fileURL: tempStoreURL)
        let sampleDevice = WOLDevice.make(mac: "00:11:22:33:44:55", ip: "192.0.2.10",
                                          name: "自检设备", vendor: "Test")
        assert(testStore.add(sampleDevice), "WOLStore 新增失败")
        assert(!testStore.add(sampleDevice), "WOLStore 未拦截重复设备")
        assert(testStore.devices().count == 1, "WOLStore 持久化失败")
        testStore.recordWake(mac: sampleDevice.mac)
        assert(testStore.device(mac: sampleDevice.mac)?.wakeCount == 1, "WOLStore 唤醒记录失败")
        testStore.remove(mac: sampleDevice.mac)
        assert(testStore.devices().isEmpty, "WOLStore 删除失败")
        try? FileManager.default.removeItem(at: tempStoreURL)
        print("[OK] WOL Magic Packet 102 字节 / MAC 解析 / 持久化校验通过")

        // 使用虚构 MAC 发包，仅验证 UDP 广播通道可用，不会唤醒任何真实设备
        if let probe = WOLService.makePacket(mac: "00:11:22:33:44:55") {
            let wolTargets = WOLService.targets(customBroadcast: "", network: network)
            let outcome = WOLService.send(packet: probe, to: wolTargets, ports: [9], repeats: 1)
            if outcome.succeeded {
                print("[OK] WOL 广播发包成功: \(outcome.sent) 个包 → \(outcome.targets.joined(separator: "、"))")
            } else {
                print("[WARN] WOL 广播发包失败: \(outcome.failures.joined(separator: "；"))")
            }
            if !outcome.failures.isEmpty {
                print("    部分目标不可用: \(outcome.failures.joined(separator: "；"))")
            }
        }
        print("[OK] 当前唤醒列表: \(WOLStore.shared.devices().count) 台设备  ·  \(WOLStore.shared.fileDescription)")

        // ARP 多来源采集：用于排查「其他机器上 MAC / 厂商 / 设备名不生效」
        let snapshot = ARPCache.collect(network: network, allowed: nil, verbose: true)
        for report in snapshot.reports { print("    \(report.oneLine)") }
        print("[OK] ARP 合并: \(snapshot.entries.count) 条 · MAC \(snapshot.macCount) 条 · 名称 \(snapshot.nameCount) 条")
        if snapshot.macCount == 0 {
            print("[WARN] 所有来源均未取得 MAC，以下为原始输出（请连同自检结果反馈开发者）：")
            for report in snapshot.reports {
                print("  --- \(report.label) [\(report.state)] ---")
                print("  \(report.head.replacingOccurrences(of: "\n", with: "\n  "))")
            }
        }
        let probeIP = network.gateway ?? network.ip
        let resolved = LANScanner.reverseLookup([probeIP])
        print("[OK] 系统反查 \(probeIP): \(resolved[probeIP] ?? "未解析到名称（该网络无反向解析记录）")")

        let networks = LocalNetwork.all()
        print("[OK] 本机网络接口 \(networks.count) 个:")
        for item in networks {
            print("  \(item.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) " +
                  "\(item.isActive ? "已连接" : "未连接")  \(item.ip.isEmpty ? "—" : item.ip)  \(item.rangeLabel)")
        }
        if let manual = network.withRange(start: "192.168.31.30", end: "192.168.31.35") {
            assert(manual.hostIPs.contains("192.168.31.33"), "手动范围生成失败")
            print("[OK] 手动范围: \(manual.hostIPs.first ?? "") - \(manual.hostIPs.last ?? "")")
        }

        let scanner = LANScanner()
        scanner.scan(network: network, progress: { done, total, ip in
            if done == total { print("… 已完成 \(done)/\(total) 次 ping 探测（\(ip)）") }
        }, completion: { hosts in
            print("[OK] 发现 \(hosts.count) 台主机:")
            for host in hosts.prefix(20) {
                let rtt = host.rttMs.map { String(format: "%.1fms", $0) } ?? "ARP"
                print("  \(host.ip.padding(toLength: 16, withPad: " ", startingAt: 0)) " +
                      "\(host.mac ?? "—") \(host.isGateway ? "[网关]" : "      ") \(rtt)  " +
                      "\(host.hostname ?? "—")  \(host.vendor)")
            }
            let withMAC = hosts.filter { $0.mac != nil }.count
            let withName = hosts.filter { $0.hostname != nil }.count
            let identified = hosts.filter {
                !$0.vendor.hasPrefix("未知供应商") && $0.vendor != "私人 MAC 地址"
                    && $0.vendor != "组播 / 虚拟地址"
            }.count
            print("[OK] 识别统计: MAC \(withMAC)/\(hosts.count) · 厂商 \(identified)/\(hosts.count) · 设备名 \(withName)/\(hosts.count)")
            let target = hosts.first(where: { $0.isGateway })?.ip ?? network.gateway ?? network.ip
            print("[…] 对 \(target) 执行端口扫描（\(ScanSettings.shared.ports.count) 个端口）")
            PortScanner().scan(ip: target, ports: ScanSettings.shared.ports,
                               timeoutMs: ScanSettings.shared.portTimeoutMs,
                               progress: { done, total in
                if done == total { print("… 端口探测 \(done)/\(total) 完成") }
            }, completion: { outcome in
                print(String(format: "[OK] 端口扫描完成: %d 个开放端口, 耗时 %.2fs",
                             outcome.results.count, outcome.elapsed))
                for result in outcome.results {
                    print("  \(result.port)  \(result.service)  \(result.banner)")
                }
                exit(0)
            })
        })
    }
}
