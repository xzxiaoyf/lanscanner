import Foundation
import Darwin

// MARK: - 唤醒端口模式

enum WOLPortMode: Int, Codable, CaseIterable {
    case both = 0, udp9 = 1, udp7 = 2

    var title: String {
        switch self {
        case .both: return "UDP 9 + 7（推荐）"
        case .udp9: return "仅 UDP 9"
        case .udp7: return "仅 UDP 7"
        }
    }

    var ports: [Int] {
        switch self {
        case .both: return [9, 7]
        case .udp9: return [9]
        case .udp7: return [7]
        }
    }

    static var optionTitles: [String] { allCases.map { $0.title } }
}

// MARK: - WOL 设备模型

struct WOLDevice: Codable, Equatable, Identifiable {
    var mac: String
    var ip: String
    var name: String
    var vendor: String
    /// 自定义定向广播地址；留空时自动使用「子网定向广播 + 255.255.255.255」
    var broadcast: String
    var portMode: WOLPortMode
    var note: String
    var addedAt: Date
    var lastWokenAt: Date?
    var wakeCount: Int

    var id: String { mac }

    var displayName: String { name.isEmpty ? ip : name }

    var lastWakeText: String {
        guard let date = lastWokenAt else { return "从未唤醒" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func make(mac: String, ip: String, name: String, vendor: String,
                     broadcast: String = "", portMode: WOLPortMode = .both) -> WOLDevice {
        WOLDevice(mac: mac, ip: ip, name: name, vendor: vendor,
                  broadcast: broadcast, portMode: portMode, note: "",
                  addedAt: Date(), lastWokenAt: nil, wakeCount: 0)
    }
}

// MARK: - 持久化（~/Library/Application Support/LANScanner/wol-devices.json）

final class WOLStore {
    static let shared = WOLStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var cache: [WOLDevice]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("LANScanner/wol-devices.json")
        }
    }

    var fileDescription: String { fileURL.path }

    func devices() -> [WOLDevice] {
        lock.lock(); defer { lock.unlock() }
        return currentLocked()
    }

    func contains(mac: String?) -> Bool {
        guard let mac else { return false }
        return devices().contains { $0.mac == mac }
    }

    func device(mac: String) -> WOLDevice? {
        devices().first { $0.mac == mac }
    }

    /// 已存在时刷新 IP / 名称 / 厂商并返回 false，否则追加并返回 true
    @discardableResult
    func add(_ device: WOLDevice) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var list = currentLocked()
        if let index = list.firstIndex(where: { $0.mac == device.mac }) {
            var existing = list[index]
            existing.ip = device.ip
            if !device.name.isEmpty { existing.name = device.name }
            if !device.vendor.isEmpty { existing.vendor = device.vendor }
            if existing.broadcast.isEmpty { existing.broadcast = device.broadcast }
            list[index] = existing
            saveLocked(list)
            return false
        }
        list.append(device)
        saveLocked(list)
        return true
    }

    func update(_ device: WOLDevice) {
        lock.lock(); defer { lock.unlock() }
        var list = currentLocked()
        guard let index = list.firstIndex(where: { $0.mac == device.mac }) else { return }
        list[index] = device
        saveLocked(list)
    }

    func remove(mac: String) {
        lock.lock(); defer { lock.unlock() }
        var list = currentLocked()
        list.removeAll { $0.mac == mac }
        saveLocked(list)
    }

    func recordWake(mac: String) {
        lock.lock(); defer { lock.unlock() }
        var list = currentLocked()
        guard let index = list.firstIndex(where: { $0.mac == mac }) else { return }
        list[index].lastWokenAt = Date()
        list[index].wakeCount += 1
        saveLocked(list)
    }

    // MARK: 内部（调用者必须已持锁）

    private func currentLocked() -> [WOLDevice] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([WOLDevice].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    private func saveLocked(_ devices: [WOLDevice]) {
        cache = devices
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(devices)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("WOLStore 写入失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - Magic Packet 与 UDP 广播

struct WOLSendResult {
    let sent: Int
    let targets: [String]
    let failures: [String]

    var succeeded: Bool { sent > 0 }

    var summary: String {
        if succeeded {
            let base = "已发送 \(sent) 个唤醒包 → \(targets.joined(separator: "、"))"
            return failures.isEmpty ? base : base + "（另有 \(failures.count) 个目标失败）"
        }
        return "发送失败：" + (failures.first ?? "未知错误")
    }
}

enum WOLService {

    /// 支持 50:92:6A:28:7A:4C / 50-92-6A-28-7A-4C / 50926A287A4C，
    /// 也兼容 arp 输出中省略前导零的形式 7c:c2:94:a:a9:a7
    static func normalizeMAC(_ raw: String) -> String? {
        let hex = raw.uppercased().filter { $0.isHexDigit }
        if hex.count == 12 {
            return stride(from: 0, to: 12, by: 2)
                .map { String(hex.dropFirst($0).prefix(2)) }
                .joined(separator: ":")
        }
        return OUIVendor.normalize(raw)
    }

    /// 6 字节 0xFF + 16 次重复的 6 字节 MAC = 102 字节
    static func makePacket(mac: String) -> [UInt8]? {
        guard let normalized = normalizeMAC(mac) else { return nil }
        let bytes = normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        packet.reserveCapacity(102)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// 发包目标：自定义广播 → 子网定向广播 → 全局广播。
    /// 子网定向广播在 macOS 上比 255.255.255.255 更常被接受，因此排在前面。
    static func targets(customBroadcast: String = "", network: LocalNetwork? = nil) -> [String] {
        var candidates: [String] = []
        let custom = customBroadcast.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, ipv4ToUInt32(custom) != nil { candidates.append(custom) }
        let net = network ?? LocalNetwork.current()
        if let net, net.mask != 0, net.broadcast != 0 {
            let directed = uint32ToIPv4(net.broadcast)
            if ipv4ToUInt32(directed) != nil { candidates.append(directed) }
        }
        candidates.append("255.255.255.255")
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func send(packet: [UInt8], to addresses: [String], ports: [Int],
                     repeats: Int = 2) -> WOLSendResult {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return WOLSendResult(sent: 0, targets: [],
                                 failures: ["无法创建 UDP socket：\(String(cString: strerror(errno)))"])
        }
        defer { _ = close(fd) }

        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled,
                       socklen_t(MemoryLayout<Int32>.size))

        var sent = 0
        var succeededTargets: [String] = []
        var failures: [String] = []
        let repeatCount = Swift.min(Swift.max(repeats, 1), 5)

        for address in addresses {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            var parsed = in_addr()
            guard address.withCString({ inet_aton($0, &parsed) != 0 }) else {
                failures.append("\(address) 不是有效 IPv4 地址")
                continue
            }
            socketAddress.sin_addr = parsed

            for port in ports {
                socketAddress.sin_port = in_port_t(port).bigEndian
                var targetOK = true
                for _ in 0..<repeatCount {
                    let count = packet.withUnsafeBytes { rawBuffer -> Int in
                        withUnsafePointer(to: &socketAddress) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                                sendto(fd, rawBuffer.baseAddress, rawBuffer.count, 0,
                                       sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    if count == packet.count {
                        sent += 1
                    } else {
                        let reason = String(cString: strerror(errno))
                        failures.append("\(address):\(port) → \(reason)")
                        targetOK = false
                        break
                    }
                }
                if targetOK { succeededTargets.append("\(address):\(port)") }
            }
        }
        return WOLSendResult(sent: sent, targets: succeededTargets, failures: failures)
    }

    /// WOL 协议无确认机制：发包后用 ping 判断设备是否已上线（仅作参考）
    static func verifyReachable(ip: String, attempts: Int = 3, timeoutMs: Int = 800,
                                completion: @escaping (Bool, TimeInterval) -> Void) {
        guard !ip.isEmpty, ipv4ToUInt32(ip) != nil else {
            DispatchQueue.main.async { completion(false, 0) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            for attempt in 0..<Swift.max(1, attempts) {
                let result = Shell.run("/sbin/ping",
                                       ["-c", "1", "-W", "\(timeoutMs)", "-q", "-n", ip])
                if result.status == 0 {
                    DispatchQueue.main.async { completion(true, Date().timeIntervalSince(started)) }
                    return
                }
                if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 1.2) }
            }
            DispatchQueue.main.async { completion(false, Date().timeIntervalSince(started)) }
        }
    }
}
