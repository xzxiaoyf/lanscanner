import Foundation

// MARK: - 数据模型

struct Host: Equatable, Identifiable {
    var id: String { ip }
    let ip: String
    var mac: String?
    var vendor: String
    /// 由 arp -a / 反向解析得到的主机名或设备名（可能为空）
    var hostname: String? = nil
    var rttMs: Double?
    var isGateway: Bool
    var isReachable: Bool
    var fromARPOnly: Bool
    var note: String

    /// 用于按 IP 数值排序，避免字典序把 .100 排在 .21 前面
    var ipValue: UInt32 {
        var value: UInt32 = 0
        for part in ip.split(separator: ".") {
            value = (value << 8) | (UInt32(part) ?? 0)
        }
        return value
    }

    /// 优先展示设备名，取不到时回退到厂商名
    var displayName: String { hostname ?? vendor }

    var statusText: String {
        if let rtt = rttMs {
            return String(format: "%.0fms 后收到 ping 命令的响应", rtt)
        }
        if fromARPOnly { return "在 ARP 缓存中发现，未响应 ping" }
        return "扫描期间找到"
    }
}

struct PortResult: Equatable {
    let port: Int
    let service: String
    let banner: String
    let responseMs: Double?
}

struct PortScanOutcome {
    let results: [PortResult]
    let scanned: Int
    let elapsed: TimeInterval
}

enum SortKey: Int {
    case ip = 0, name = 1, vendor = 2
}

enum HostFilter: Int {
    case all = 0, gateway = 1, reachable = 2, scanned = 3
}

enum PortPreset: Int, CaseIterable {
    case common = 0, wellKnown = 1, all = 2, custom = 3

    var title: String {
        switch self {
        case .common: return "常用端口"
        case .wellKnown: return "1–1024"
        case .all: return "1–65535"
        case .custom: return "自定义"
        }
    }
}

// MARK: - 扫描参数

final class ScanSettings {
    static let shared = ScanSettings()
    private let defaults = UserDefaults.standard

    private init() {}

    var pingTimeoutMs: Int {
        get { clamp(defaults.integer(forKey: "pingTimeoutMs"), 100, 5000, 400) }
        set { defaults.set(newValue, forKey: "pingTimeoutMs") }
    }
    var portTimeoutMs: Int {
        get { clamp(defaults.integer(forKey: "portTimeoutMs"), 100, 5000, 400) }
        set { defaults.set(newValue, forKey: "portTimeoutMs") }
    }
    var pingConcurrency: Int {
        get { clamp(defaults.integer(forKey: "pingConcurrency"), 4, 256, 48) }
        set { defaults.set(newValue, forKey: "pingConcurrency") }
    }
    var portPreset: PortPreset {
        get { PortPreset(rawValue: defaults.integer(forKey: "portPreset")) ?? .common }
        set { defaults.set(newValue.rawValue, forKey: "portPreset") }
    }
    var customPorts: String {
        get { defaults.string(forKey: "customPorts") ?? "1-1024" }
        set { defaults.set(newValue, forKey: "customPorts") }
    }

    // MARK: 网络唤醒（WOL）默认参数

    var wolPortMode: WOLPortMode {
        get { WOLPortMode(rawValue: defaults.integer(forKey: "wolPortMode")) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "wolPortMode") }
    }
    /// 自定义广播地址；留空时自动使用「子网定向广播 + 255.255.255.255」
    var wolBroadcast: String {
        get { defaults.string(forKey: "wolBroadcast") ?? "" }
        set { defaults.set(newValue, forKey: "wolBroadcast") }
    }
    var wolRepeatCount: Int {
        get { clamp(defaults.integer(forKey: "wolRepeatCount"), 1, 5, 2) }
        set { defaults.set(newValue, forKey: "wolRepeatCount") }
    }
    var wolVerifyAfterWake: Bool {
        get { defaults.object(forKey: "wolVerifyAfterWake") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wolVerifyAfterWake") }
    }

    /// 选中的扫描接口（空字符串 = 自动使用默认路由接口）
    var selectedInterface: String {
        get { defaults.string(forKey: "selectedInterface") ?? "" }
        set { defaults.set(newValue, forKey: "selectedInterface") }
    }
    var useManualRange: Bool {
        get { defaults.bool(forKey: "useManualRange") }
        set { defaults.set(newValue, forKey: "useManualRange") }
    }
    var manualStartIP: String {
        get { defaults.string(forKey: "manualStartIP") ?? "" }
        set { defaults.set(newValue, forKey: "manualStartIP") }
    }
    var manualEndIP: String {
        get { defaults.string(forKey: "manualEndIP") ?? "" }
        set { defaults.set(newValue, forKey: "manualEndIP") }
    }
    /// 扫描前是否显示网络选择面板
    var showNetworkPicker: Bool {
        get { defaults.object(forKey: "showNetworkPicker") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showNetworkPicker") }
    }
    /// 超时档位：0 低 / 1 中 / 2 高
    var timeoutLevel: Int {
        get { defaults.object(forKey: "timeoutLevel") as? Int ?? 1 }
        set {
            defaults.set(newValue, forKey: "timeoutLevel")
            pingTimeoutMs = [200, 400, 900][Swift.min(Swift.max(newValue, 0), 2)]
        }
    }

    var ports: [Int] {
        switch portPreset {
        case .common: return PortLists.common
        case .wellKnown: return Array(1...1024)
        case .all: return Array(1...65535)
        case .custom: return PortLists.parse(customPorts)
        }
    }

    private func clamp(_ value: Int, _ min: Int, _ max: Int, _ fallback: Int) -> Int {
        if value == 0 { return fallback }
        return Swift.min(Swift.max(value, min), max)
    }

    func reset() {
        pingTimeoutMs = 400
        portTimeoutMs = 400
        pingConcurrency = 48
        portPreset = .common
        customPorts = "1-1024"
        selectedInterface = ""
        useManualRange = false
        manualStartIP = ""
        manualEndIP = ""
        showNetworkPicker = true
        timeoutLevel = 1
        wolPortMode = .both
        wolBroadcast = ""
        wolRepeatCount = 2
        wolVerifyAfterWake = true
    }
}

enum PortLists {
    /// 常见服务端口，覆盖路由器、NAS、打印机、摄像头、开发服务与远程桌面
    static let common: [Int] = [
        20, 21, 22, 23, 25, 53, 67, 68, 69, 80, 110, 111, 123, 135, 137, 138, 139,
        143, 161, 443, 445, 465, 500, 515, 548, 554, 587, 631, 873, 993, 995,
        1080, 1433, 1720, 1723, 1883, 1900, 2049, 2121, 3000, 3128, 3306, 3389,
        3689, 5000, 5001, 5060, 5357, 5432, 5555, 5800, 5900, 5988, 6379, 6443,
        6666, 7000, 8000, 8008, 8080, 8081, 8088, 8443, 8545, 8554, 8888, 9000,
        9001, 9100, 9200, 9999, 10000, 11211, 27017, 32400, 49152, 50000, 62078
    ]

    /// 解析 "80,443,8000-8100" 形式，最多 5000 个端口
    static func parse(_ text: String) -> [Int] {
        var result: Set<Int> = []
        for raw in text.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.contains("-"), let dash = token.firstIndex(of: "-") {
                let a = Int(String(token[..<dash]).trimmingCharacters(in: .whitespaces)) ?? 0
                let b = Int(String(token[token.index(after: dash)...]).trimmingCharacters(in: .whitespaces)) ?? 0
                if a > 0, b >= a {
                    for p in a...Swift.min(b, 65535) {
                        result.insert(p)
                        if result.count >= 5000 { break }
                    }
                }
            } else if let p = Int(token), p > 0, p <= 65535 {
                result.insert(p)
            }
            if result.count >= 5000 { break }
        }
        return result.sorted()
    }
}

// MARK: - 端口服务名

enum ServiceNames {
    static func name(for port: Int) -> String {
        return map[port] ?? "未知服务"
    }

    static let map: [Int: String] = [
        20: "FTP 数据", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP",
        53: "DNS", 67: "DHCP", 68: "DHCP", 69: "TFTP", 80: "HTTP",
        110: "POP3", 111: "RPC", 123: "NTP", 135: "MS RPC", 137: "NetBIOS",
        138: "NetBIOS", 139: "NetBIOS", 143: "IMAP", 161: "SNMP",
        443: "HTTPS", 445: "SMB", 465: "SMTPS", 500: "IPSec", 515: "LPD 打印",
        548: "AFP", 554: "RTSP", 587: "SMTP", 631: "IPP 打印", 873: "rsync",
        993: "IMAPS", 995: "POP3S", 1080: "SOCKS 代理", 1433: "SQL Server",
        1720: "H.323", 1723: "PPTP", 1883: "MQTT", 1900: "UPnP",
        2049: "NFS", 2121: "FTP", 3000: "Web 开发服务", 3128: "HTTP 代理",
        3306: "MySQL", 3389: "远程桌面", 3689: "DAAP / AirPlay",
        5000: "AirPlay / UPnP", 5001: "Web 服务", 5060: "SIP", 5357: "WSDAPI",
        5432: "PostgreSQL", 5555: "ADB", 5800: "VNC over HTTP", 5900: "VNC",
        5988: "WBEM", 6379: "Redis", 6443: "Kubernetes API", 6666: "自定义服务",
        7000: "AirPlay 视频", 8000: "HTTP 备用", 8008: "Chromecast",
        8080: "HTTP 备用 / 代理", 8081: "Web 管理", 8088: "Web 管理",
        8443: "HTTPS 备用", 8545: "JSON-RPC", 8554: "RTSP 备用",
        8888: "Web 管理", 9000: "Web 管理", 9001: "Web 管理",
        9100: "打印机 RAW", 9200: "Elasticsearch", 9999: "设备管理",
        10000: "Webmin", 11211: "Memcached", 27017: "MongoDB",
        32400: "Plex", 49152: "动态端口", 50000: "设备管理", 62078: "lockdownd"
    ]
}

// MARK: - MAC → 供应商（OUI）

enum OUIVendor {
    /// 把 arp 输出中含省略前导零的地址（7c:c2:94:a:a9:a7）归一化为 7C:C2:94:0A:A9:A7
    /// 其余格式（连字符 / 点分 / 连续 12 位）由 MACAddress 统一兼容
    static func normalize(_ raw: String) -> String? { MACAddress.normalize(raw) }

    static func name(for mac: String?) -> String {
        guard let mac, let normalized = normalize(mac) else { return "未知供应商" }
        let octets = normalized.split(separator: ":").map(String.init)
        let prefix = octets.prefix(3).joined(separator: ":")
        let hex = octets.joined()

        loadDatabase()
        // 内置表提供完整公司名（与参考界面一致），优先于外部库的缩写
        if let builtin = table[prefix] { return builtin }
        // nmap 库含 6 位 OUI、7 位 MA-M、9 位 MA-S 前缀，按最长匹配
        for length in [9, 7, 6] {
            if let vendor = database?[String(hex.prefix(length))] { return vendor }
        }
        // 库未命中时才按地址类型兜底，避免「本地管理位」屏蔽掉真实厂商
        let octet = UInt8(octets[0], radix: 16) ?? 0
        if octet & 0x02 != 0 { return "私人 MAC 地址" }
        if octet & 0x01 != 0 { return "组播 / 虚拟地址" }
        return "未知供应商（\(prefix)）"
    }

    // MARK: 完整 IEEE OUI 数据库（外部 oui.txt 优先，二进制内嵌副本兜底）

    private static var database: [String: String]?
    private static let databaseLock = NSLock()
    /// 数据库来源说明，供自检与「关于」面板确认
    private(set) static var sourceLabel: String = "未加载"

    static var databaseCount: Int {
        loadDatabase()
        return database?.count ?? 0
    }

    static var sourceDescription: String {
        loadDatabase()
        return sourceLabel
    }

    private static func loadDatabase() {
        databaseLock.lock(); defer { databaseLock.unlock() }
        if database != nil { return }
        var map: [String: String] = [:]
        var source = "未加载"
        if let (text, label) = loadDatabaseText() {
            source = label
            for rawLine in text.split(separator: "\n") {
                let line = String(rawLine)
                if line.hasPrefix("#") || line.isEmpty { continue }
                guard let space = line.firstIndex(of: " ") else { continue }
                let prefix = String(line[..<space]).uppercased()
                guard [6, 7, 9].contains(prefix.count),
                      prefix.allSatisfy({ $0.isHexDigit }) else { continue }
                let vendor = String(line[line.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
                if !vendor.isEmpty { map[prefix] = vendor }
            }
        }
        database = map
        sourceLabel = "\(source) · \(map.count) 条"
    }

    private static func loadDatabaseText() -> (String, String)? {
        // 外部文件优先：便于在目标机器上自行放置/更新 OUI 库
        for url in externalCandidates() {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.utf8.count > 10_000 else { continue }
            return (text, url.path)
        }
        // 兜底：编译进二进制的完整副本。即使 .app 资源缺失、只复制了可执行文件、
        // 或可读路径与编译机完全不同，厂商识别仍然可用。
        let embedded = OUIEmbedded.text
        return embedded.isEmpty ? nil : (embedded, "内置数据库")
    }

    private static func externalCandidates() -> [URL] {
        var candidates: [URL] = []
        func add(_ url: URL?) { if let url { candidates.append(url) } }
        // 可通过环境变量显式指定（例如 LANSCANNER_OUI=/path/oui.txt）
        if let custom = ProcessInfo.processInfo.environment["LANSCANNER_OUI"], !custom.isEmpty {
            add(URL(fileURLWithPath: custom))
        }
        add(Bundle.main.resourceURL?.appendingPathComponent("oui.txt"))
        add(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/oui.txt"))
        add(Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("oui.txt"))
        add(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LANScanner/oui.txt"))
        // 开发环境：源码目录 / .build 上溯 / 当前工作目录
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        add(sourceDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/oui.txt"))
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        add(execDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/oui.txt"))
        add(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/oui.txt"))
        return candidates
    }

    static let table: [String: String] = [
        // 小米 / 生态链（与参考界面中的路由器及设备一致）
        "50:92:6A": "Beijing Xiaomi Mobile Software Co., Ltd",
        "7C:C2:94": "Beijing Xiaomi Mobile Software Co., Ltd",
        "54:48:E6": "Beijing Xiaomi Mobile Software Co., Ltd",
        "B4:60:ED": "Beijing Xiaomi Mobile Software Co., Ltd",
        "E4:FE:43": "Beijing Xiaomi Mobile Software Co., Ltd",
        "64:09:80": "Beijing Xiaomi Mobile Software Co., Ltd",
        "04:CF:8C": "XIAOMI Electronics,CO.,LTD",
        "70:70:FC": "GOLD&WATER INDUSTRIAL LIMITED",
        "3C:C5:DD": "Hui Zhou Gaoshengda Technology Co., Ltd",
        "C8:69:CD": "Xiaomi Communications Co., Ltd",
        "E4:AA:EC": "Tianjin Hualai Technology Co., Ltd",
        "34:FA:1C": "Beijing Xiaomi Mobile Software Co., Ltd",
        // Apple
        "3C:22:FB": "Apple, Inc.", "A4:83:E7": "Apple, Inc.", "F0:18:98": "Apple, Inc.",
        "8C:58:84": "Apple, Inc.", "D8:1C:79": "Apple, Inc.", "AC:BC:32": "Apple, Inc.",
        "00:25:00": "Apple, Inc.", "68:D9:3C": "Apple, Inc.", "18:AF:8F": "Apple, Inc.",
        "6C:72:E7": "Apple, Inc.", "F4:F9:51": "Apple, Inc.", "B8:E8:56": "Apple, Inc.",
        "00:26:BB": "Apple, Inc.", "DC:2B:2A": "Apple, Inc.", "10:DD:B1": "Apple, Inc.",
        // 华为 / 荣耀 / 手机厂商
        "00:1E:10": "Huawei Technologies Co., Ltd", "28:6E:D4": "Huawei Device Co., Ltd",
        "AC:E2:15": "Huawei Device Co., Ltd", "D4:61:9F": "Huawei Device Co., Ltd",
        "08:63:61": "Huawei Device Co., Ltd", "7C:1C:68": "Honor Device Co., Ltd",
        "AC:37:43": "OnePlus Technology Co., Ltd", "94:65:2D": "OnePlus Technology Co., Ltd",
        "F4:EE:14": "OPPO Mobile Telecommunications", "18:87:D5": "vivo Mobile Communication",
        "44:1A:FA": "vivo Mobile Communication", "00:12:FB": "Samsung Electronics Co., Ltd",
        "5C:49:7D": "Samsung Electronics Co., Ltd", "8C:77:12": "Samsung Electronics Co., Ltd",
        "00:1C:62": "LG Electronics", "00:19:C5": "Sony Corporation",
        // 网络设备
        "C4:E9:84": "TP-LINK Technologies Co., Ltd", "50:C7:BF": "TP-LINK Technologies Co., Ltd",
        "EC:08:6B": "TP-LINK Technologies Co., Ltd", "14:CC:20": "TP-LINK Technologies Co., Ltd",
        "98:DA:C4": "TP-LINK Technologies Co., Ltd", "30:B5:C2": "TP-LINK Technologies Co., Ltd",
        "00:0F:B5": "NETGEAR, Inc.", "C4:04:15": "NETGEAR, Inc.", "A0:40:A0": "NETGEAR, Inc.",
        "00:1B:FC": "ASUSTek Computer Inc.", "1C:87:2C": "ASUSTek Computer Inc.",
        "2C:4D:54": "ASUSTek Computer Inc.", "38:2C:4A": "ASUSTek Computer Inc.",
        "00:1B:11": "D-Link Corporation", "C8:BE:19": "D-Link Corporation",
        "00:06:25": "Cisco-Linksys, LLC", "00:18:F8": "Cisco-Linksys, LLC",
        "00:1B:D4": "Cisco Systems, Inc.", "58:8D:09": "Cisco Systems, Inc.",
        "00:15:6D": "Ubiquiti Networks Inc.", "04:18:D6": "Ubiquiti Networks Inc.",
        "24:A4:3C": "Ubiquiti Networks Inc.", "78:8A:20": "Ubiquiti Networks Inc.",
        "74:AC:B9": "Ubiquiti Networks Inc.", "F8:8F:CA": "Google, Inc.",
        "54:60:09": "Google, Inc.", "3C:5A:B4": "Google, Inc.", "1C:F2:9A": "Google, Inc.",
        "0C:47:C9": "Amazon Technologies Inc.", "44:65:0D": "Amazon Technologies Inc.",
        "68:37:E9": "Amazon Technologies Inc.", "F0:D2:F1": "Amazon Technologies Inc.",
        // 计算机 / 虚拟机 / 开发板
        "00:14:22": "Dell Inc.", "B8:CA:3A": "Dell Inc.", "18:66:DA": "Dell Inc.",
        "3C:52:82": "Hewlett Packard", "00:25:B3": "Hewlett Packard", "70:5A:0F": "Hewlett Packard",
        "00:1B:21": "Intel Corporation", "3C:97:0E": "Intel Corporation", "A4:34:D9": "Intel Corporation",
        "00:15:5D": "Microsoft Corporation", "00:03:FF": "Microsoft Corporation",
        "00:0C:29": "VMware, Inc.", "00:50:56": "VMware, Inc.", "00:05:69": "VMware, Inc.",
        "08:00:27": "Oracle VirtualBox", "00:1C:42": "Parallels, Inc.",
        "B8:27:EB": "Raspberry Pi Foundation", "DC:A6:32": "Raspberry Pi Trading Ltd",
        "E4:5F:01": "Raspberry Pi Trading Ltd", "28:CD:C1": "Raspberry Pi Trading Ltd",
        "24:0A:C4": "Espressif Inc.", "3C:71:BF": "Espressif Inc.", "84:CC:A8": "Espressif Inc.",
        "A0:20:A6": "Espressif Inc.", "EC:FA:BC": "Espressif Inc.", "7C:DF:A1": "Espressif Inc.",
        "08:3A:8D": "Espressif Inc.", "D8:A0:1D": "Espressif Inc.", "C8:C9:A3": "Espressif Inc.",
        "4C:EB:D6": "Espressif Inc.", "58:BF:25": "Espressif Inc.", "10:06:1C": "Espressif Inc.",
        // 安防 / 存储 / 影音 / 打印
        "C0:56:E3": "Hikvision Digital Technology", "44:19:B6": "Hikvision Digital Technology",
        "BC:AD:28": "Hikvision Digital Technology", "4C:BD:8F": "Hikvision Digital Technology",
        "3C:EF:8E": "Zhejiang Dahua Technology", "90:02:A9": "Zhejiang Dahua Technology",
        "00:11:32": "Synology Incorporated", "90:09:D0": "Synology Incorporated",
        "00:08:9B": "QNAP Systems, Inc.", "24:5E:BE": "QNAP Systems, Inc.",
        "00:0E:58": "Sonos, Inc.", "5C:AA:FD": "Sonos, Inc.", "B8:E9:37": "Sonos, Inc.",
        "00:00:85": "Canon, Inc.", "00:1E:8F": "Canon, Inc."
    ]
}

// MARK: - 备注持久化

final class NotesStore {
    static let shared = NotesStore()
    private let defaults = UserDefaults.standard
    private init() {}

    func note(for ip: String) -> String {
        defaults.string(forKey: "note.\(ip)") ?? ""
    }
    func setNote(_ text: String, for ip: String) {
        defaults.set(text, forKey: "note.\(ip)")
    }
}
