import Foundation
import Darwin

// MARK: - 外部命令执行

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var timedOut: Bool = false
    }

    /// timeout > 0 时启用超时保护。arp -a 在 DNS 配置异常的机器上可能长时间反解，
    /// 若不设上限会阻塞整轮扫描，导致 MAC 与厂商一起缺失。
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // 边产生边累积输出：超时被终止时也能保留已写入的内容，
        // 且避免「整块 readDataToEndOfFile 尚未读完就取走空数据」的竞态。
        let outputLock = NSLock()
        var outputData = Data()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if !chunk.isEmpty {
                outputLock.lock(); outputData.append(chunk); outputLock.unlock()
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            return Result(status: -1, output: "")
        }

        var timedOut = false
        if timeout > 0 {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                _ = exited.wait(timeout: .now() + 1)
            }
        } else {
            exited.wait()
        }

        handle.readabilityHandler = nil
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty {
                outputLock.lock(); outputData.append(remaining); outputLock.unlock()
            }
            readDone.signal()
        }
        _ = readDone.wait(timeout: .now() + 3)
        outputLock.lock(); let data = outputData; outputLock.unlock()
        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return Result(status: timedOut ? -1 : status,
                      output: String(decoding: data, as: UTF8.self),
                      timedOut: timedOut)
    }
}

// MARK: - 本机网段信息

struct LocalNetwork {
    let interface: String
    /// 友好名称：Wi-Fi / Ethernet / USB 10/100/1000 LAN …
    let name: String
    /// 无 IPv4 时为空字符串（接口未连接）
    let ip: String
    let mask: UInt32
    let network: UInt32
    let broadcast: UInt32
    let gateway: String?
    let localMAC: String?
    let isActive: Bool
    let isDefaultRoute: Bool
    var hostIPs: [String]
    var isManualRange: Bool = false
    var manualStart: String? = nil
    var manualEnd: String? = nil

    var prefix: Int { mask.nonzeroBitCount }
    var cidr: String { ip.isEmpty ? "未连接" : "\(uint32ToIPv4(network))/\(prefix)" }
    var subnetLabel: String { "\(uint32ToIPv4(network)) – \(uint32ToIPv4(broadcast))" }
    var displayName: String { name.isEmpty ? interface : "\(name) (\(interface))" }
    var isScannable: Bool { !ip.isEmpty && !hostIPs.isEmpty }

    var firstHost: UInt32 { broadcast > network + 1 ? network + 1 : network }
    var lastHost: UInt32 { broadcast > network + 1 ? broadcast - 1 : broadcast }
    var rangeStart: String { ip.isEmpty ? "" : uint32ToIPv4(firstHost) }
    var rangeEnd: String { ip.isEmpty ? "" : uint32ToIPv4(lastHost) }
    var rangeLabel: String { ip.isEmpty ? "—" : "\(rangeStart) - \(rangeEnd)" }
    var scanLabel: String {
        isManualRange ? "\(manualStart ?? rangeStart) - \(manualEnd ?? rangeEnd)"
                      : cidr
    }

    func contains(_ candidate: String) -> Bool {
        guard let value = ipv4ToUInt32(candidate) else { return false }
        return value > network && value < broadcast
    }

    /// 用手动起止 IP 覆盖扫描范围（最多 4096 个地址）
    func withRange(start: String, end: String) -> LocalNetwork? {
        guard let a = ipv4ToUInt32(start), let b = ipv4ToUInt32(end), b >= a else { return nil }
        let count = Swift.min(Int(b - a) + 1, 4096)
        var addresses: [String] = []
        for offset in 0..<count {
            let candidate = uint32ToIPv4(a + UInt32(offset))
            if candidate == ip { continue }
            addresses.append(candidate)
        }
        var copy = self
        copy.hostIPs = addresses
        copy.isManualRange = true
        copy.manualStart = start
        copy.manualEnd = end
        return copy
    }

    /// 枚举本机所有可用网络接口（含未连接但存在的物理接口）
    static func all() -> [LocalNetwork] {
        let route = Shell.run("/sbin/route", ["-n", "get", "default"]).output
        let defaultGateway = value(for: "gateway", in: route)
        let defaultInterface = value(for: "interface", in: route)
        let portNames = hardwarePortNames()

        let interfaceList = Shell.run("/sbin/ifconfig", ["-l"]).output
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)

        var result: [LocalNetwork] = []
        for interface in interfaceList where interface != "lo0" {
            let parsed = parseIfconfig(interface: interface)
            let hasEthernet = parsed.mac != nil
            let usableIP = parsed.ip.map { !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") } ?? false
            // 只保留物理网卡，或已配置 IPv4 的其它接口
            guard hasEthernet || usableIP else { continue }

            let ip = parsed.ip ?? ""
            let mask = parsed.maskHex.flatMap { UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0
            let ipValue = ipv4ToUInt32(ip) ?? 0
            let network = mask == 0 ? 0 : ipValue & mask
            let broadcast = mask == 0 ? 0 : network | ~mask
            let hosts = mask == 0 ? [] : generateHosts(network: network, broadcast: broadcast, ownIP: ip)
            let isDefault = interface == defaultInterface

            result.append(LocalNetwork(
                interface: interface,
                name: portNames[interface] ?? (interface.hasPrefix("en") ? "以太网" : interface),
                ip: ip,
                mask: mask,
                network: network,
                broadcast: broadcast,
                gateway: isDefault ? defaultGateway : nil,
                localMAC: OUIVendor.normalize(parsed.mac ?? ""),
                isActive: parsed.active && usableIP,
                isDefaultRoute: isDefault,
                hostIPs: hosts))
        }
        return result.sorted { lhs, rhs in
            if lhs.isDefaultRoute != rhs.isDefaultRoute { return lhs.isDefaultRoute }
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.name < rhs.name
        }
    }

    /// 依据设置选择扫描网络：指定接口 → 默认路由接口 → 首个活跃接口
    static func current() -> LocalNetwork? {
        let networks = all()
        let settings = ScanSettings.shared
        var chosen: LocalNetwork?
        if !settings.selectedInterface.isEmpty {
            chosen = networks.first { $0.interface == settings.selectedInterface && $0.isScannable }
        }
        if chosen == nil { chosen = networks.first { $0.isDefaultRoute && $0.isScannable } }
        if chosen == nil { chosen = networks.first { $0.isActive && $0.isScannable } }
        if chosen == nil { chosen = networks.first { $0.isScannable } }
        guard var network = chosen else { return nil }
        if settings.useManualRange {
            network = network.withRange(start: settings.manualStartIP,
                                        end: settings.manualEndIP) ?? network
        }
        return network
    }

    static func detect() -> LocalNetwork? { current() }

    private static func generateHosts(network: UInt32, broadcast: UInt32, ownIP: String) -> [String] {
        let first = network + 1
        let last = broadcast > network + 1 ? broadcast - 1 : broadcast
        guard last >= first else { return [] }
        let count = Swift.min(Int(last - first) + 1, 4096)
        var hosts: [String] = []
        for offset in 0..<count {
            let candidate = uint32ToIPv4(first + UInt32(offset))
            if candidate == ownIP { continue }
            hosts.append(candidate)
        }
        return hosts
    }

    private static func parseIfconfig(interface: String) -> (ip: String?, maskHex: String?, mac: String?, active: Bool) {
        let output = Shell.run("/sbin/ifconfig", [interface]).output
        var ip: String?
        var netmask: String?
        var mac: String?
        var statusSeen = false
        var statusActive = false
        for line in output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !tokens.isEmpty else { continue }
            if let idx = tokens.firstIndex(of: "inet"), idx + 1 < tokens.count {
                ip = tokens[idx + 1]
                if let m = tokens.firstIndex(of: "netmask"), m + 1 < tokens.count {
                    netmask = tokens[m + 1]
                }
            }
            if tokens[0] == "ether", tokens.count > 1 { mac = tokens[1] }
            if tokens[0] == "status" {
                statusSeen = true
                statusActive = tokens.contains("active")
            }
        }
        let active = statusSeen ? statusActive : output.contains("<UP,")
        return (ip, netmask, mac, active)
    }

    /// networksetup -listallhardwareports → [en2: Wi-Fi, en0: Ethernet …]
    private static func hardwarePortNames() -> [String: String] {
        let output = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]).output
        var result: [String: String] = [:]
        var port: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                port = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:"), let port {
                let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                result[device] = port
            }
        }
        return result
    }

    private static func value(for key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + ":") else { continue }
            return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

func ipv4ToUInt32(_ ip: String) -> UInt32? {
    let parts = ip.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
}

func uint32ToIPv4(_ value: UInt32) -> String {
    "\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
}

// MARK: - 局域网主机发现

/// 线程安全计数器（避免并发闭包对同一变量的 inout 独占访问冲突）
final class Counter {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

final class LANScanner {
    private let stateLock = NSLock()
    private var cancelled = false
    private let settings = ScanSettings.shared

    func cancel() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    /// progress / completion 均在主线程回调
    func scan(network: LocalNetwork,
              progress: @escaping (_ done: Int, _ total: Int, _ currentIP: String) -> Void,
              completion: @escaping ([Host]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var responders: [String: Double] = [:]
            let resultLock = NSLock()
            let done = Counter()
            let total = network.hostIPs.count
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = self.settings.pingConcurrency

            for ip in network.hostIPs {
                queue.addOperation {
                    if self.isCancelled {
                        self.bump(done, total, ip, progress)
                        return
                    }
                    let result = Shell.run("/sbin/ping",
                                          ["-c", "1", "-W", "\(self.settings.pingTimeoutMs)", "-q", "-n", ip])
                    if result.status == 0 {
                        let rtt = Self.parseRTT(result.output) ?? 0
                        resultLock.lock(); responders[ip] = rtt; resultLock.unlock()
                    }
                    self.bump(done, total, ip, progress)
                }
            }
            queue.waitUntilAllOperationsAreFinished()

            // MAC 主来源改为内核路由表（sysctl），再叠加 arp / netstat 备用来源。
            // 某些机器上 /usr/sbin/arp 会返回空或超时，只依赖它会导致「主机能发现、
            // MAC 全为 —、厂商全部未知」，内核通道不依赖外部命令与进程权限。
            let allowed = Set(network.hostIPs)
            let snapshot = ARPCache.collect(network: network, allowed: allowed, verbose: false)
            var entries: [String: (String?, Double?, String?)] = [:]
            for (ip, entry) in snapshot.entries where allowed.contains(ip) {
                entries[ip] = (entry.mac, nil, entry.hostname)
            }
            // 部分机器 arp -a 全为 "?"（无本地反解记录），补一次系统解析器反查
            let missing = entries.filter { $0.value.2 == nil }.map(\.key).sorted()
            let extraNames = Self.reverseLookup(Array(missing.prefix(128)))
            for (ip, name) in extraNames {
                if let current = entries[ip] { entries[ip] = (current.0, current.1, name) }
            }
            for (ip, rtt) in responders {
                let previous = entries[ip]
                entries[ip] = (previous?.0, rtt, previous?.2)
            }
            // 部分系统会自动清理 ARP 缓存，导致「主机在线但表里没有 MAC」。
            // 对这些地址做一轮定向单包探测，再直接重读内核路由表补齐。
            let missingMAC = responders.keys.filter { entries[$0]?.0 == nil }.sorted()
            if !missingMAC.isEmpty {
                let probes = Array(missingMAC.prefix(64))
                let probeQueue = OperationQueue()
                probeQueue.maxConcurrentOperationCount = 12
                for ip in probes {
                    probeQueue.addOperation {
                        _ = Shell.run("/sbin/ping", ["-c", "1", "-W", "300", "-q", "-n", ip], timeout: 2)
                    }
                }
                probeQueue.waitUntilAllOperationsAreFinished()
                let refreshed = ARPCache.readKernelARP().entries
                for ip in probes {
                    guard let mac = refreshed[ip]?.mac else { continue }
                    let previous = entries[ip]
                    entries[ip] = (mac, previous?.1, previous?.2)
                }
            }
            if let gateway = network.gateway, allowed.contains(gateway), entries[gateway] == nil {
                entries[gateway] = (nil, nil, nil)
            }

            var hosts: [Host] = entries.map { ip, info in
                let mac = info.0
                return Host(ip: ip,
                     mac: mac,
                     vendor: OUIVendor.name(for: mac),
                     hostname: info.2,
                     rttMs: info.1,
                     isGateway: ip == network.gateway,
                     isReachable: info.1 != nil,
                     fromARPOnly: info.1 == nil,
                     note: NotesStore.shared.note(for: ip))
            }
            hosts.sort { $0.ipValue < $1.ipValue }
            DispatchQueue.main.async { completion(hosts) }
        }
    }

    private func bump(_ done: Counter, _ total: Int, _ ip: String,
                      _ progress: @escaping (Int, Int, String) -> Void) {
        let current = done.increment()
        if current % 4 == 0 || current == total {
            DispatchQueue.main.async { progress(current, total, ip) }
        }
    }

    static func parseRTT(_ output: String) -> Double? {
        guard let marker = output.range(of: "round-trip min/avg/max/stddev = ") else { return nil }
        let tail = output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = tail.split(separator: "/")
        guard fields.count >= 2, let avg = Double(fields[1]) else { return nil }
        return avg
    }

    /// 用系统解析器（DNS / mDNS / hosts）反查主机名。
    /// 部分机器的 arp -a 全部返回 "?"，此时这是设备名的主要来源。
    static func reverseLookup(_ ips: [String]) -> [String: String] {
        guard !ips.isEmpty else { return [:] }
        let lock = NSLock()
        var resolved: [String: String] = [:]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 8
        for ip in ips {
            queue.addOperation {
                let output = Shell.run("/usr/bin/dscacheutil",
                                       ["-q", "host", "-a", "ip_address", ip],
                                       timeout: 2).output
                for rawLine in output.split(separator: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("name: ") else { continue }
                    let name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    // 过滤反解失败时返回的 in-addr.arpa 字面量与 IP 本身
                    guard !name.isEmpty, !name.contains("in-addr.arpa"),
                          ipv4ToUInt32(name) == nil else { continue }
                    lock.lock(); resolved[ip] = name; lock.unlock()
                    break
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return resolved
    }

    struct ARPEntry {
        let mac: String?
        let hostname: String?
    }

    /// arp -a 行：xiaoqiang (192.168.31.1) at 50:92:6a:28:7a:4c on en2 ifscope [ethernet]
    /// 兼容：(incomplete)、连字符 MAC、点分 MAC、名称字段为 IP 字面量、permanent 等修饰词。
    /// 逐行解析而非整段正则，避免不同系统版本输出细节差异导致整表丢失。
    static func parseARP(_ output: String) -> [String: ARPEntry] {
        guard let ipRegex = try? NSRegularExpression(
            pattern: "\\(([0-9]{1,3}(?:\\.[0-9]{1,3}){3})\\)") else { return [:] }
        var result: [String: ARPEntry] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            let ns = line as NSString
            guard let match = ipRegex.firstMatch(in: line,
                                                range: NSRange(location: 0, length: ns.length)) else { continue }
            let ip = ns.substring(with: match.range(at: 1))
            let namePart = ns.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespaces)
            let after = ns.substring(from: match.range.upperBound)

            var mac: String?
            if let atRange = after.range(of: " at ", options: [.caseInsensitive]) {
                let tokens = after[atRange.upperBound...]
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                // 正常情况下首 token 即 MAC；某些版本会在 at 后插入 permanent / pub 等修饰词
                for token in tokens.prefix(4) {
                    if let normalized = MACAddress.normalize(String(token)) {
                        mac = normalized
                        break
                    }
                }
            }
            let candidateName = namePart.split(separator: " ").last.map(String.init) ?? namePart
            let hostname: String? = {
                guard !candidateName.isEmpty, candidateName != "?",
                      candidateName != "(incomplete)",
                      ipv4ToUInt32(candidateName) == nil else { return nil }
                return candidateName
            }()
            // 既无 MAC 又无名称的行（例如 at (incomplete)）不是有效邻居记录
            guard mac != nil || hostname != nil else { continue }
            if let old = result[ip] {
                result[ip] = ARPEntry(mac: old.mac ?? mac, hostname: old.hostname ?? hostname)
            } else {
                result[ip] = ARPEntry(mac: mac, hostname: hostname)
            }
        }
        return result
    }
}

// MARK: - TCP 端口扫描（非阻塞 connect + poll）

final class PortScanner {
    private let stateLock = NSLock()
    private var cancelled = false

    func cancel() {
        stateLock.lock(); cancelled = true; stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    /// progress / completion 均在主线程回调
    func scan(ip: String, ports: [Int], timeoutMs: Int,
              progress: @escaping (_ done: Int, _ total: Int) -> Void,
              completion: @escaping (PortScanOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            var found: [PortResult] = []
            let resultLock = NSLock()
            let done = Counter()
            let total = ports.count

            // 使用信号量控制并发度，避免 concurrentPerform 受 CPU 核心数限制导致慢速扫描
            let group = DispatchGroup()
            let concurrencyLimit = DispatchSemaphore(value: 64)
            for port in ports {
                concurrencyLimit.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        concurrencyLimit.signal()
                        group.leave()
                    }
                    var outcome: PortResult?
                    if !self.isCancelled {
                        outcome = Self.probe(ip: ip, port: port, timeoutMs: timeoutMs)
                    }
                    if let outcome {
                        resultLock.lock(); found.append(outcome); resultLock.unlock()
                    }
                    let current = done.increment()
                    if current % 8 == 0 || current == total {
                        DispatchQueue.main.async { progress(current, total) }
                    }
                }
            }
            group.wait()

            let elapsed = Date().timeIntervalSince(started)
            let sorted = found.sorted { $0.port < $1.port }
            DispatchQueue.main.async {
                completion(PortScanOutcome(results: sorted, scanned: total, elapsed: elapsed))
            }
        }
    }

    /// 这些服务通常主动发送欢迎横幅，值得短暂读取；其余端口不等待数据以免拖慢扫描
    private static let bannerPorts: Set<Int> = [
        21, 22, 23, 25, 110, 143, 465, 587, 993, 995, 1080, 1433, 1521, 1883,
        3306, 3389, 5432, 5900, 6379, 11211
    ]

    private static func probe(ip: String, port: Int, timeoutMs: Int) -> PortResult? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(ip))

        let started = Date()
        let rc = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return nil }
            var descriptor = pollfd()
            descriptor.fd = fd
            descriptor.events = Int16(POLLOUT)
            let ready = poll(&descriptor, 1, Int32(timeoutMs))
            guard ready > 0 else { return nil }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                  socketError == 0 else { return nil }
        }

        let elapsedMs = Date().timeIntervalSince(started) * 1000
        var banner = ""
        if bannerPorts.contains(port) {
            banner = readBanner(fd: fd, originalFlags: originalFlags)
        }
        return PortResult(port: port,
                          service: ServiceNames.name(for: port),
                          banner: banner,
                          responseMs: elapsedMs)
    }

    private static func readBanner(fd: Int32, originalFlags: Int32) -> String {
        var timeout = timeval(tv_sec: 0, tv_usec: 220_000)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, UnsafeRawPointer(pointer),
                           socklen_t(MemoryLayout<timeval>.size))
        }
        _ = fcntl(fd, F_SETFL, originalFlags)
        var buffer = [CChar](repeating: 0, count: 256)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for index in 0..<count {
            let byte = UInt8(bitPattern: buffer[index])
            if byte == 9 || byte == 10 || byte == 13 || byte >= 32 {
                bytes.append(byte)
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        return String(firstLine.prefix(90))
    }
}
