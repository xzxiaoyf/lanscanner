import Foundation
import Darwin

// MARK: - MAC 地址归一化

/// 兼容 arp / netstat / 内核路由表 / 用户输入的各种写法：
///   7c:c2:94:a:a9:a7（省略前导零）、50-92-6A-28-7A-4C、
///   5092.6a28.7a4c（点分）、50926A287A4C（连续 12 位）
enum MACAddress {
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text = String(text.dropFirst(2)) }
        guard !text.isEmpty else { return nil }

        var compact: String?
        if text.allSatisfy({ $0.isHexDigit }), text.count == 12 {
            compact = text.uppercased()
        } else if text.contains(":") || text.contains("-") {
            let separator: Character = text.contains(":") ? ":" : "-"
            let parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6,
                  parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isHexDigit } }) else { return nil }
            compact = parts.map { String(repeating: "0", count: 2 - $0.count) + $0 }.joined().uppercased()
        } else if text.contains(".") {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3,
                  parts.allSatisfy({ $0.count == 4 && $0.allSatisfy { $0.isHexDigit } }) else { return nil }
            compact = parts.joined().uppercased()
        }
        guard let compact, compact.count == 12, compact.allSatisfy({ $0.isHexDigit }) else { return nil }

        var bytes: [UInt8] = []
        var index = compact.startIndex
        for _ in 0..<6 {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - 采集报告

struct ARPSourceReport {
    let label: String
    let command: String
    let status: Int32
    let timedOut: Bool
    let lines: Int
    let parsed: Int
    /// 原始输出前若干行，用于跨机器排查
    let head: String

    var state: String { timedOut ? "超时" : (status == 0 ? "正常" : "失败 rc=\(status)") }
    var oneLine: String {
        "\(label.padding(toLength: 20, withPad: " ", startingAt: 0)) " +
        "\(state)  ·  输出 \(lines) 行  ·  解析 \(parsed) 条  ·  \(command)"
    }
}

// MARK: - ARP 邻居表采集

/// 为什么需要内核通道：
/// 部分机器上 /usr/sbin/arp 会因权限、TCC、签名环境或系统版本差异返回空结果，
/// 导致 ping 能发现主机、但 MAC 与厂商全部缺失。内核路由表（PF_ROUTE / RTF_LLINFO）
/// 由 sysctl 直接读取，不依赖外部命令、PATH、DNS 与进程权限，作为最可靠的主来源。
enum ARPCache {
    struct Snapshot {
        var entries: [String: LANScanner.ARPEntry] = [:]
        var reports: [ARPSourceReport] = []
        var kernelCount: Int = 0
        var macCount: Int { entries.values.filter { $0.mac != nil }.count }
        var nameCount: Int { entries.values.filter { $0.hostname != nil }.count }

        /// 合并规则：已有的非空 MAC / 名称优先；跳过既无 MAC 又无名称的
        /// incomplete 条目，否则会把「ping 失败留下的 ARP 半解析记录」当成在线主机。
        mutating func merge(_ incoming: [String: LANScanner.ARPEntry]) {
            for (ip, entry) in incoming {
                guard entry.mac != nil || entry.hostname != nil else { continue }
                guard let old = entries[ip] else {
                    entries[ip] = entry
                    continue
                }
                entries[ip] = LANScanner.ARPEntry(mac: old.mac ?? entry.mac,
                                                   hostname: old.hostname ?? entry.hostname)
            }
        }
    }

    private static let stateLock = NSLock()
    private static var cachedSnapshot: Snapshot?

    static func lastSnapshot() -> Snapshot? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedSnapshot
    }

    private static func store(_ snapshot: Snapshot) {
        stateLock.lock(); cachedSnapshot = snapshot; stateLock.unlock()
    }

    /// 主入口。verbose=true 时会额外尝试所有备用来源并保留原始输出，供 --arpdiag 使用。
    static func collect(network: LocalNetwork?,
                        allowed: Set<String>? = nil,
                        verbose: Bool = false) -> Snapshot {
        var snapshot = Snapshot()

        // 1) 内核路由表：零外部依赖，速度最快
        let kernel = readKernelARP()
        snapshot.kernelCount = kernel.entries.count
        snapshot.merge(kernel.entries)
        snapshot.reports.append(ARPSourceReport(
            label: "内核路由表",
            command: "sysctl CTL_NET/PF_ROUTE/NET_RT_FLAGS/RTF_LLINFO",
            status: kernel.errno == 0 ? 0 : Int32(kernel.errno),
            timedOut: false,
            lines: kernel.messages,
            parsed: kernel.entries.count,
            head: kernel.errno == 0
                ? "读取 \(kernel.messages) 条路由消息，其中 \(kernel.entries.count) 条含链路层地址（消息头 \(kernel.headerUsed) 字节）"
                : "sysctl 读取失败：errno=\(kernel.errno)"))

        // 应急开关：完全跳过外部 arp/netstat 命令，只使用内核表
        // LANSCANNER_ARP_KERNEL_ONLY=1 LANScanner --selftest
        if ProcessInfo.processInfo.environment["LANSCANNER_ARP_KERNEL_ONLY"] == "1" {
            snapshot.reports.append(ARPSourceReport(
                label: "外部命令", command: "已由 LANSCANNER_ARP_KERNEL_ONLY=1 跳过",
                status: 0, timedOut: false, lines: 0, parsed: 0, head: "仅内核通道"))
            store(snapshot)
            return snapshot
        }

        func runARP(_ args: [String], _ label: String, _ timeout: TimeInterval) {
            let result = Shell.run("/usr/sbin/arp", args, timeout: timeout)
            let parsed = LANScanner.parseARP(result.output)
            snapshot.merge(parsed)
            snapshot.reports.append(ARPSourceReport(
                label: label,
                command: "/usr/sbin/arp " + args.joined(separator: " "),
                status: result.status,
                timedOut: result.timedOut,
                lines: lineCount(result.output),
                parsed: parsed.count,
                head: head(result.output)))
        }

        // 2) 标准 arp 数字模式（MAC + 无反解）
        runARP(["-a", "-n"], "arp 数字模式", 5)
        // 3) 名称模式（设备名主要来源之一）
        runARP(["-a"], "arp 名称模式", verbose ? 3 : 1.5)

        // 4) 备用链路：主来源失效或诊断模式下全部尝试
        if verbose || snapshot.macCount == 0 {
            runARP(["-an"], "arp 合并参数", 5)
            if let interface = network?.interface, !interface.isEmpty {
                runARP(["-a", "-n", "-i", interface], "arp 指定接口", 5)
            }

            let routeResult = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeout: 5)
            let routeEntries = parseNetstatRoutes(routeResult.output)
            snapshot.merge(routeEntries)
            snapshot.reports.append(ARPSourceReport(
                label: "netstat 主机路由",
                command: "/usr/sbin/netstat -rn -f inet",
                status: routeResult.status,
                timedOut: routeResult.timedOut,
                lines: lineCount(routeResult.output),
                parsed: routeEntries.count,
                head: head(routeResult.output)))

            // 逐条查询：样本 IP，用于确认单条 arp 查询是否可用
            var samples: [String] = []
            if verbose {
                samples.append(contentsOf: [network?.gateway].compactMap { $0 })
                samples.append(contentsOf: (network?.hostIPs ?? []).prefix(6))
            } else if let allowed {
                samples = allowed.filter { snapshot.entries[$0]?.mac == nil }.sorted()
            }
            samples = Array(NSOrderedSet(array: samples).compactMap { $0 as? String }.prefix(32))
            if !samples.isEmpty {
                var found: [String: LANScanner.ARPEntry] = [:]
                let lock = NSLock()
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 8
                for ip in samples {
                    queue.addOperation {
                        let result = Shell.run("/usr/sbin/arp", ["-n", ip], timeout: 1.5)
                        let parsed = LANScanner.parseARP(result.output)
                        if let entry = parsed[ip] ?? parsed.values.first(where: { $0.mac != nil }) {
                            lock.lock(); found[ip] = entry; lock.unlock()
                        }
                    }
                }
                queue.waitUntilAllOperationsAreFinished()
                snapshot.merge(found)
                snapshot.reports.append(ARPSourceReport(
                    label: "arp 逐条查询",
                    command: "/usr/sbin/arp -n <IP>（\(samples.count) 个样本）",
                    status: 0, timedOut: false,
                    lines: samples.count, parsed: found.count,
                    head: samples.joined(separator: "、") + "\n命中 \(found.count) 条"))
            }
        }

        store(snapshot)
        return snapshot
    }

    // MARK: 内核路由表

    /// sysctl(CTL_NET/PF_ROUTE/AF_INET/NET_RT_FLAGS/RTF_LLINFO) 与 `arp -a` 读取的是同一张表。
    /// 返回 rt_msghdr2 消息，其中 RTAX_DST 为 sockaddr_in，RTAX_GATEWAY 为 sockaddr_dl（含 MAC）。
    static func readKernelARP() -> (entries: [String: LANScanner.ARPEntry],
                                   messages: Int, errno: Int32, headerUsed: Int) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var needed = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else {
            return ([:], 0, Int32(Darwin.errno), 0)
        }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &needed, nil, 0) == 0 else {
            return ([:], 0, Int32(Darwin.errno), 0)
        }
        let limit = Swift.min(needed, buffer.count)

        // 不同 macOS 版本 / 架构返回的路由消息头可能略有差异。
        // 先用 SDK 声明的 rt_msghdr2 长度，若解析不到再自适应其它常见长度。
        let preferred = MemoryLayout<rt_msghdr2>.size
        let candidates = NSOrderedSet(array: [preferred,
                                              MemoryLayout<rt_msghdr>.size,
                                              96, 92, 88, 84, 80, 16])
            .compactMap { $0 as? Int }
        var best: (entries: [String: LANScanner.ARPEntry], messages: Int, header: Int) = ([:], 0, preferred)
        for headerSize in candidates {
            let parsed = parseRoutingBuffer(buffer, limit: limit, headerSize: headerSize)
            if parsed.entries.count > best.entries.count {
                best = (parsed.entries, parsed.messages, headerSize)
            }
            if headerSize == preferred, !parsed.entries.isEmpty { break }
        }
        return (best.entries, best.messages, 0, best.header)
    }

    private static func parseRoutingBuffer(_ buffer: [UInt8], limit: Int, headerSize: Int)
        -> (entries: [String: LANScanner.ARPEntry], messages: Int) {
        guard headerSize >= 16 else { return ([:], 0) }
        var entries: [String: LANScanner.ARPEntry] = [:]
        var messages = 0
        var offset = 0

        while offset + headerSize <= limit {
            let messageLength = Int(buffer[offset]) | (Int(buffer[offset + 1]) << 8)
            guard messageLength >= headerSize, offset + messageLength <= limit else { break }
            let addressMask = readUInt32(buffer, offset + 12)
            let end = offset + messageLength
            var ip: String?
            var mac: String?
            var saOffset = offset + headerSize

            for bit in 0..<8 where (addressMask & (1 << UInt32(bit))) != 0 {
                guard saOffset + 2 <= end else { break }
                let saLength = Int(buffer[saOffset])
                let family = Int(buffer[saOffset + 1])
                if bit == 0, family == AF_INET, saOffset + 8 <= end {
                    ip = "\(buffer[saOffset + 4]).\(buffer[saOffset + 5])." +
                         "\(buffer[saOffset + 6]).\(buffer[saOffset + 7])"
                }
                if bit == 1, family == AF_LINK, saOffset + 8 <= end {
                    let nameLength = Int(buffer[saOffset + 5])
                    let addressLength = Int(buffer[saOffset + 6])
                    let start = saOffset + 8 + nameLength
                    if addressLength > 0, start + addressLength <= end {
                        let bytes = (0..<Swift.min(addressLength, 6)).map { buffer[start + $0] }
                        mac = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                    }
                }
                let step = saLength == 0 ? 16 : (saLength + 3) & ~3
                guard step > 0 else { break }
                saOffset += step
            }
            messages += 1
            if let ip, let mac {
                entries[ip] = LANScanner.ARPEntry(mac: MACAddress.normalize(mac), hostname: nil)
            }
            offset += messageLength
        }
        return (entries, messages)
    }

    /// netstat -rn -f inet 的 UHLWI 主机路由行：
    /// 192.168.31.1   50:92:6a:28:7a:4c   UHLWIir   en2   1193
    static func parseNetstatRoutes(_ output: String) -> [String: LANScanner.ARPEntry] {
        var result: [String: LANScanner.ARPEntry] = [:]
        for rawLine in output.split(separator: "\n") {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2, ipv4ToUInt32(tokens[0]) != nil,
                  let mac = MACAddress.normalize(tokens[1]),
                  result[tokens[0]] == nil else { continue }
            result[tokens[0]] = LANScanner.ARPEntry(mac: mac, hostname: nil)
        }
        return result
    }

    private static func readUInt32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | (UInt32(buffer[offset + 1]) << 8) |
        (UInt32(buffer[offset + 2]) << 16) | (UInt32(buffer[offset + 3]) << 24)
    }

    private static func lineCount(_ output: String) -> Int {
        output.isEmpty ? 0 : output.split(separator: "\n").count
    }

    private static func head(_ output: String, maxLines: Int = 8) -> String {
        let lines = output.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "（无输出）" }
        let shown = lines.prefix(maxLines).joined(separator: "\n")
        let suffix = lines.count > maxLines ? "\n…（共 \(lines.count) 行）" : ""
        return String((shown + suffix).prefix(1400))
    }
}

// MARK: - 跨机器诊断

enum ARPDiagnostics {
    static func run() {
        print("=== LANScanner ARP 诊断 (\(AppVersionInfo.short) / 构建 \(AppVersionInfo.build)) ===")
        #if arch(arm64)
        let arch = "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        let arch = "x86_64 (Intel)"
        #else
        let arch = "未知"
        #endif
        print("系统: \(ProcessInfo.processInfo.operatingSystemVersionString)  运行架构: \(arch)")
        print("可执行文件: \(AppVersionInfo.executablePath)")
        print("构建时间: \(AppVersionInfo.builtAt)   uid=\(getuid()) euid=\(geteuid())")
        print("当前目录: \(FileManager.default.currentDirectoryPath)")
        print("OUI 数据库: \(OUIVendor.sourceDescription)")
        print("arp 存在: \(FileManager.default.fileExists(atPath: "/usr/sbin/arp"))  " +
              "可执行: \(FileManager.default.isExecutableFile(atPath: "/usr/sbin/arp"))  " +
              "架构: \(Shell.run("/usr/bin/lipo", ["-archs", "/usr/sbin/arp"], timeout: 2).output.trimmingCharacters(in: .whitespacesAndNewlines))")

        let network = LocalNetwork.detect()
        if let network {
            print("扫描网络: \(network.displayName)  \(network.ip)  \(network.cidr)  网关 \(network.gateway ?? "—")")
            let pingResult = Shell.run("/sbin/ping", ["-c", "1", "-W", "500", "-q", "-n", network.gateway ?? network.ip], timeout: 3)
            print("ping 测试: rc=\(pingResult.status) 超时=\(pingResult.timedOut)")
            let pingHead = pingResult.output.split(separator: "\n").prefix(3).joined(separator: "\n")
            if !pingHead.isEmpty { print("    \(pingHead.replacingOccurrences(of: "\n", with: "\n    "))") }
        } else {
            print("[WARN] 未识别到本机 IPv4 网段")
        }
        print("")
        print("--- ARP 数据来源 ---")
        let snapshot = ARPCache.collect(network: network, allowed: nil, verbose: true)
        for report in snapshot.reports {
            print(report.oneLine)
            print("    原始输出: \(report.head.replacingOccurrences(of: "\n", with: "\n    "))")
        }
        print("")
        print("--- 合并结果：\(snapshot.entries.count) 条，MAC \(snapshot.macCount) 条，名称 \(snapshot.nameCount) 条 ---")
        for (ip, entry) in snapshot.entries.sorted(by: { $0.key < $1.key }) {
            print("  \(ip.padding(toLength: 16, withPad: " ", startingAt: 0)) " +
                  "\(entry.mac ?? "—")  \(entry.hostname ?? "—")  " +
                  "\(OUIVendor.name(for: entry.mac))")
        }
        print("")
        print("--- 判读 ---")
        if snapshot.kernelCount > 0 {
            print("内核路由表可用（\(snapshot.kernelCount) 条），MAC 与厂商识别应正常。")
        } else {
            print("内核路由表读取失败或为空；请检查上方各来源的原始输出与错误码。")
        }
        print("若所有来源都为 0 条，请把本输出完整贴回开发者，以便针对该系统版本继续适配。")
        print("应急验证：LANSCANNER_ARP_KERNEL_ONLY=1 <程序> --selftest 可只走内核表。")
    }
}
