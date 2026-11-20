import Foundation
import AppKit
import Network
import Darwin

let fm = FileManager.default
struct AppError: Error { let message: String; init(_ message: String) { self.message = message } }
func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8) }
func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
func fingerprint(_ path: String) -> String? {
    var s = stat()
    guard lstat(path, &s) == 0 else { return nil }
    return "\(s.st_dev):\(s.st_ino):\(s.st_uid):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
}
func canonical(_ path: String) -> String {
    if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
    return URL(fileURLWithPath: path).standardizedFileURL.path
}
func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
func base(_ path: String) -> String { (path as NSString).lastPathComponent }
func run(_ executable: String, _ args: [String], timeout: Double = 45) throws -> (Int32, String) {
    let file = fm.temporaryDirectory.appendingPathComponent("chipspace-command-\(UUID().uuidString)")
    fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    defer { try? fm.removeItem(at: file) }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
    p.standardOutput = handle; p.standardError = handle
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"; env["LC_ALL"] = "C"
    p.environment = env
    try p.run()
    let end = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < end { usleep(50_000) }
    if p.isRunning {
        p.terminate(); usleep(200_000)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit(); throw AppError("The operation timed out. Nothing else will be attempted; rescan before retrying.")
    }
    p.waitUntilExit()
    return (p.terminationStatus, String(text(file).prefix(2_000_000)))
}

// Separate policy from report labels: the browser never chooses a filesystem path.
func allowedFile(_ path: String, home: String) -> Bool {
    guard path.hasPrefix(home + "/") else { return false }
    let r = String(path.dropFirst(home.count + 1))
    let exact: Set<String> = ["Library/Caches/pip", "Library/Caches/uv", "Library/Caches/node-gyp", "Library/Caches/go-build", "Library/Caches/org.swift.swiftpm", "Library/Caches/Dia", "Library/Caches/Arc", "Library/Caches/Codex", "Library/Caches/company.thebrowser.dia", "Library/Caches/company.thebrowser.Browser", ".npm/_cacache", ".npm/_npx", ".cache/pip", ".cache/uv", ".ollama/models"]
    if exact.contains(r) { return true }
    if [home + "/Library/Developer/Xcode/DerivedData", home + "/Library/Developer/Xcode/iOS DeviceSupport"].contains(parent(path)) { return true }
    if parent(path) == home + "/Library/Logs" && !base(path).hasPrefix("com.apple.") { return true }
    return parent(path) == home + "/.cache/huggingface/hub" && base(path).hasPrefix("models--")
}
func guardFile(_ path: String, home: String, expected: String) throws {
    guard allowedFile(path, home: home), !path.contains("\n"), !path.contains("\r"), !path.contains("\t"), canonical(path) == path else { throw AppError("This location is protected, unrecognized, or redirected. Direct cleanup is disabled.") }
    var current = path
    while current != "/" {
        var s = stat()
        guard lstat(current, &s) == 0, (s.st_mode & S_IFMT) != S_IFLNK else { throw AppError("Cannot validate \(current): the path is inaccessible or contains a symbolic link. Rescan first.") }
        current = parent(current)
    }
    var s = stat(); var ps = stat()
    guard lstat(path, &s) == 0, lstat(parent(path), &ps) == 0, s.st_uid == getuid(), s.st_dev == ps.st_dev, fingerprint(path) == expected else { throw AppError("This folder changed since the scan, is not owned by you, or is a mount point. Close its app and rescan.") }
}
func measured(_ path: String) throws -> Int64 {
    let (rc, out) = try run("/usr/bin/du", ["-x", "-k", "-s", path], timeout: 90)
    let lines = out.split(separator: "\n")
    guard rc == 0, lines.count == 1, let first = lines.first?.split(separator: "\t").first, let size = Int64(first) else { throw AppError("This folder could not be read completely. Cleanup is blocked. Review scan coverage or grant Chipspace Full Disk Access.") }
    return size * 1024
}

struct Item: Codable {
    var id: String; var path: String; var name: String; var bytes: Int64
    var complete: Bool; var action: String; var explanation: String; var advice: String
    var identity: String; var parentID: String?; var category: String
    var delta: Int64?; var removed: Bool = false
}
struct Snapshot: Codable { var home: String; var date: Double; var reportPath: String; var items: [Item]; var errors: String }
struct Ticket { var id: String; var kind: String; var target: String; var mode: String; var identity: String; var name: String; var bytes: Int64; var expires: Date }

func category(_ p: String) -> String {
    if p.contains("huggingface") || p.contains("/.ollama") || p.contains("/.lmstudio") { return "models" }
    if p.contains("/Developer") || p.contains("iOSSimulatorRuntime") || p.contains("AppleDeveloperDocumentation") || p.contains("MetalToolchain") { return "development" }
    if p.contains("/Caches") || p.contains("/.cache") || p.contains("/.npm") || p.contains("/Logs") { return "caches" }
    if p.contains("/Application Support") || p.contains("/Containers") || p.contains("/Group Containers") || p.contains("/.codex") { return "apps" }
    if p.hasPrefix("/System/") || p.hasPrefix("/private/") || p.hasPrefix("/Library") { return "system" }
    return "personal"
}
func title(_ p: String, home: String) -> String {
    let known = [home + "/Library/Caches": "App caches", home + "/Library/Logs": "App logs", home + "/.cache": "Tool caches", home + "/.cache/huggingface/hub": "Hugging Face models", home + "/.cache/huggingface": "Hugging Face", home + "/.ollama/models": "Ollama models", home + "/.ollama": "Ollama", home + "/.npm": "npm packages", home + "/.npm/_cacache": "npm download cache", home + "/Library/Developer/Xcode/iOS DeviceSupport": "iPhone debugging support", home + "/Library/Developer/Xcode/DerivedData": "Xcode build output", home + "/Library/Developer/CoreSimulator/Devices": "Simulator devices", home + "/Library/Developer/CoreSimulator": "Simulator data", "/System/Library/AssetsV2": "Apple system assets", "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime": "iOS simulator runtimes", "/Library/Developer/CoreSimulator": "Shared simulator support", "/System/Volumes/VM": "Virtual memory", "/private/var": "macOS working data", home + "/Library/Caches/company.thebrowser.dia": "Dia updater cache", home + "/Library/Application Support": "Application data", home + "/Library/Containers": "App containers", home + "/Library/Group Containers": "Shared app containers"]
    if let n = known[p] { return n }
    if base(p).hasPrefix("models--") { return base(p).components(separatedBy: "--").dropFirst(2).joined(separator: "/") }
    return base(p)
}

final class Store {
    let home: String; let resources: URL; let data: URL
    let lock = NSRecursiveLock()
    var snapshot: Snapshot?; var phase = "idle"; var message = "Ready to scan."; var scanProcess: Process?
    var scanLog: URL?; var tickets: [String: Ticket] = [:]; var activity: [[String: Any]] = []
    init(home: String, resources: URL, data: URL) throws {
        self.home = home; self.resources = resources; self.data = data
        try fm.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let d = try? Data(contentsOf: data.appendingPathComponent("latest.json")), let saved = try? JSONDecoder().decode(Snapshot.self, from: d), saved.home == home { snapshot = saved }
        if let d = try? Data(contentsOf: data.appendingPathComponent("activity.json")), let saved = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { activity = saved }
    }
    func locked<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }
    func record(_ label: String, _ detail: String) {
        locked {
            activity.insert(["date": Date().timeIntervalSince1970, "label": label, "detail": detail], at: 0)
            activity = Array(activity.prefix(100)); try? json(activity).write(to: data.appendingPathComponent("activity.json"), options: .atomic)
        }
    }
    func persist() { if let s = snapshot, let d = try? JSONEncoder().encode(s) { try? d.write(to: data.appendingPathComponent("latest.json"), options: .atomic) } }
    func importReport(_ report: URL) throws {
        let tsv = text(report.appendingPathComponent("inventory.tsv"))
        guard !tsv.isEmpty else { throw AppError("The scan did not produce an inventory.") }
        var descriptions: [String: (String, String)] = [:]; var rowID = ""; var why = ""
        for line in text(report.appendingPathComponent("report.txt")).components(separatedBy: "\n") {
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") { rowID = String(line[line.index(after: line.startIndex)..<end]) }
            if line.hasPrefix("  What it does: ") { why = String(line.dropFirst(16)) }
            if line.hasPrefix("  Deletion/prevention: ") { descriptions[rowID] = (why, String(line.dropFirst(23))) }
        }
        let old = locked { snapshot?.items ?? [] }
        let oldByPath = Dictionary(old.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [Item] = []; var seen = Set<String>()
        for line in tsv.components(separatedBy: "\n").dropFirst() {
            let col = line.components(separatedBy: "\t")
            guard col.count == 5, let kb = Int64(col[1]), kb >= 0, col[4].hasPrefix("/"), !seen.contains(col[4]) else { continue }
            let path = col[4]; seen.insert(path)
            var d = descriptions[col[0]] ?? ("Application or system support data.", "Inspect in its owning app. Direct cleanup is disabled.")
            if path == home + "/Library/Developer/Xcode/iOS DeviceSupport" { d = ("Debugging symbols and support files retained for different versions of iOS on physical devices.", "Explore the version folders and keep the ones needed for debugging and old crash logs. A matching connected device can regenerate support.") }
            if path == home + "/Library/Developer/Xcode/DerivedData" { d = ("Xcode build products, indexes, and downloaded build dependencies, grouped by project.", "Explore individual project folders. Quit Xcode and builds before cleanup; rebuilding takes time and may require downloads.") }
            if path == home + "/Library/Developer/Xcode" { d = ("Xcode's working files, device support, build output, archives, and user configuration.", "Explore the components. Archives and settings are not disposable caches; avoid deleting this whole folder.") }
            if path == home + "/Library/Caches" { d = ("Working caches created by your apps. They can include downloads, updater staging, and offline content.", "Explore individual apps. Only recognized cache locations can be cleared directly, after the owning app and its updater have stopped.") }
            d.1 = d.1.replacingOccurrences(of: "this script", with: "Chipspace").replacingOccurrences(of: "the runtime menu", with: "Manage simulators").replacingOccurrences(of: "the simulator menu", with: "Manage simulators")
            var item = Item(id: UUID().uuidString, path: path, name: title(path, home: home), bytes: kb * 1024, complete: col[2] == "yes", action: allowedFile(path, home: home) ? "conditional" : "inspect", explanation: d.0, advice: d.1, identity: fingerprint(path) ?? "missing", parentID: nil, category: category(path))
            if let prior = oldByPath[path], prior.complete && item.complete && !prior.removed { item.delta = item.bytes - prior.bytes }
            items.append(item)
        }
        guard !items.isEmpty else { throw AppError("No readable folders were found. Check macOS permissions.") }
        let ids = Dictionary(items.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        for index in items.indices {
            var p = parent(items[index].path)
            while p != "/" { if let id = ids[p] { items[index].parentID = id; break }; p = parent(p) }
        }
        let errors = text(report.appendingPathComponent("scan-errors.txt"))
        let measuredAt = (try? report.appendingPathComponent("inventory.tsv").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        locked { snapshot = Snapshot(home: home, date: measuredAt, reportPath: report.path, items: items, errors: errors); persist() }
    }
    func state() -> [String: Any] {
        locked {
            var disk = statfs(); _ = statfs(home, &disk)
            let total = Int64(disk.f_blocks) * Int64(disk.f_bsize); let free = Int64(disk.f_bavail) * Int64(disk.f_bsize)
            var progress = message
            if phase == "scanning", let log = scanLog {
                let lines = text(log).components(separatedBy: "\n").filter { $0.hasPrefix("Scanning ") }
                if let last = lines.last { progress = last.replacingOccurrences(of: home, with: "~") }
            }
            let items: [[String: Any]] = (snapshot?.items ?? []).map { i in
                var d: [String: Any] = ["id": i.id, "path": i.path.replacingOccurrences(of: home, with: "~", options: .anchored), "name": i.name, "bytes": i.bytes, "complete": i.complete, "action": i.action, "explanation": i.explanation, "advice": i.advice, "category": i.category, "removed": i.removed]
                if let p = i.parentID { d["parentId"] = p }; if let delta = i.delta { d["delta"] = delta }; return d
            }
            return ["phase": phase, "message": progress, "date": snapshot?.date ?? 0, "items": items, "total": total, "free": free, "machine": Host.current().localizedName ?? "This Mac", "os": ProcessInfo.processInfo.operatingSystemVersionString, "errors": (snapshot?.errors ?? "").replacingOccurrences(of: home, with: "~"), "activity": activity]
        }
    }
    func startScan() throws {
        try locked {
            guard phase != "scanning" && phase != "working" else { throw AppError("Wait for the current operation to finish.") }
            phase = "scanning"; message = "Reading storage…"; tickets.removeAll()
            let reports = data.appendingPathComponent("Reports"); try fm.createDirectory(at: reports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log = data.appendingPathComponent("scan.log"); fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]); scanLog = log
            let handle = try FileHandle(forWritingTo: log)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-f", resources.appendingPathComponent("engine.command").path, "--scan-only", "--output", reports.path, "--timeout", "45"]
            p.standardOutput = handle; p.standardError = handle; scanProcess = p
            p.terminationHandler = { [weak self] process in
                try? handle.close(); guard let self = self else { return }
                do {
                    guard process.terminationStatus == 0 else { throw AppError("Scan stopped before completion. Check the coverage details and try again.") }
                    guard let line = text(log).components(separatedBy: "\n").first(where: { $0.hasPrefix("Reports: ") }) else { throw AppError("No scan report was produced.") }
                    try self.importReport(URL(fileURLWithPath: String(line.dropFirst(9))))
                    self.locked { self.phase = "idle"; self.message = "Scan complete."; self.scanProcess = nil }
                    self.record("Scan completed", "Folder measurements refreshed. No files were deleted.")
                } catch {
                    self.locked { self.phase = "error"; self.message = (error as? AppError)?.message ?? error.localizedDescription; self.scanProcess = nil }
                    self.record("Scan incomplete", self.message)
                }
            }
            do { try p.run() } catch { phase = "error"; message = error.localizedDescription; try? handle.close(); throw error }
        }
    }
    func beginWork() throws { try locked { guard phase != "scanning" && phase != "working" else { throw AppError("Wait for the current operation to finish.") }; phase = "working"; message = "Checking selected item…" } }
    func endWork() { locked { phase = "idle"; message = "Ready." } }
    func find(_ id: String) throws -> Item { try locked { guard let i = snapshot?.items.first(where: { $0.id == id && !$0.removed }) else { throw AppError("This item is no longer in the current scan. Select it again after rescanning.") }; return i } }
    func simulatorList() throws -> [[String: Any]] {
        let (rc, output) = try run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 25)
        guard rc == 0, let d = output.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { throw AppError("Xcode simulator management is unavailable. Install/select Xcode, or use Xcode Settings → Components.") }
        var list: [[String: Any]] = []
        for (id, r) in dict where UUID(uuidString: id) != nil {
            list.append(["id": id, "kind": "runtime", "name": "iOS / \(r["version"] as? String ?? "runtime")", "detail": "Build \(r["build"] as? String ?? "unknown") · \(r["state"] as? String ?? "unknown")", "bytes": r["sizeBytes"] ?? 0, "enabled": r["deletable"] as? Bool ?? false, "signature": "\(id)|\(r["version"] ?? "")|\(r["build"] ?? "")"])
        }
        let (drc, dout) = try run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 25)
        if drc == 0, let d = dout.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let devices = obj["devices"] as? [String: [[String: Any]]] {
            for (runtime, group) in devices { for dev in group {
                guard let id = dev["udid"] as? String, UUID(uuidString: id) != nil else { continue }
                list.append(["id": id, "kind": "device", "name": dev["name"] ?? "Simulator", "detail": "\(dev["state"] ?? "unknown") · \(runtime.components(separatedBy: ".").last ?? runtime)", "bytes": dev["dataPathSize"] ?? 0, "enabled": (dev["state"] as? String) == "Shutdown", "signature": "\(id)|\(runtime)|\(dev["name"] ?? "")", "booted": (dev["state"] as? String) == "Booted"])
            } }
        }
        return list.sorted { ($0["bytes"] as? NSNumber)?.int64Value ?? 0 > ($1["bytes"] as? NSNumber)?.int64Value ?? 0 }
    }
    func prepare(_ body: [String: Any]) throws -> [String: Any] {
        try beginWork(); defer { endWork() }
        let kind = body["kind"] as? String ?? "file"; let id = body["id"] as? String ?? ""
        let mode = body["mode"] as? String ?? "trash"
        var ticket: Ticket; var consequence: String
        if kind == "file" {
            guard ["trash", "delete"].contains(mode) else { throw AppError("Unsupported action.") }
            let i = try find(id); try guardFile(i.path, home: home, expected: i.identity)
            let bytes = try measured(i.path); try guardFile(i.path, home: home, expected: i.identity)
            ticket = Ticket(id: UUID().uuidString, kind: kind, target: id, mode: mode, identity: i.identity, name: i.name, bytes: bytes, expires: Date().addingTimeInterval(180))
            consequence = i.advice + (mode == "trash" ? " Moving to Trash does not free space until you empty that item from Trash in Finder." : " Permanent deletion cannot be undone. Actual freed space can be lower because of shared blocks or snapshots.")
        } else {
            guard ["runtime", "device"].contains(kind), UUID(uuidString: id) != nil else { throw AppError("Select one simulator from the live inventory.") }
            let all = try simulatorList()
            guard let s = all.first(where: { $0["id"] as? String == id && $0["kind"] as? String == kind }), s["enabled"] as? Bool == true else { throw AppError("This simulator cannot currently be removed. Shut down running devices first.") }
            if kind == "runtime", all.contains(where: { $0["booted"] as? Bool == true }) { throw AppError("Shut down all simulated devices before removing a runtime.") }
            ticket = Ticket(id: UUID().uuidString, kind: kind, target: id, mode: "delete", identity: s["signature"] as? String ?? "", name: s["name"] as? String ?? "Simulator", bytes: (s["bytes"] as? NSNumber)?.int64Value ?? 0, expires: Date().addingTimeInterval(180))
            consequence = kind == "runtime" ? "Removes this simulator OS package using Apple's simctl. Devices using it cannot run until you reinstall the runtime. Quit Xcode and stop all tests first." : "Permanently removes this simulated device and all its test apps and data. The OS runtime stays installed. Quit Xcode and stop all tests first."
        }
        locked { tickets = tickets.filter { $0.value.expires > Date() }; tickets[ticket.id] = ticket }
        return ["ticket": ticket.id, "name": ticket.name, "bytes": ticket.bytes, "mode": ticket.mode, "consequence": consequence, "phrase": ticket.mode == "trash" ? "TRASH" : "DELETE"]
    }
    func execute(_ body: [String: Any]) throws -> [String: Any] {
        try beginWork(); defer { endWork() }
        let key = body["ticket"] as? String ?? ""
        guard let t = locked({ tickets.removeValue(forKey: key) }), t.expires > Date() else { throw AppError("This confirmation expired or was already used. Review the item again.") }
        guard body["closed"] as? Bool == true, body["confirmation"] as? String == (t.mode == "trash" ? "TRASH" : "DELETE") else { throw AppError("Nothing was deleted. Confirm you have closed the owning app and type the exact confirmation word.") }
        var info = ""; var s = statfs(); _ = statfs(home, &s); let before = Int64(s.f_bavail) * Int64(s.f_bsize)
        do {
            if t.kind == "file" {
                let item = try find(t.target); try guardFile(item.path, home: home, expected: t.identity)
                if t.mode == "trash" {
                    var resulting: NSURL?; try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resulting)
                    info = "Moved to Trash. Disk space is not freed until this item is removed from Trash."
                } else {
                    let (rc, out) = try run("/bin/rm", ["-rfx", "--", item.path], timeout: 180)
                    guard rc == 0, !fm.fileExists(atPath: item.path) else { throw AppError("Deletion was partial or the app recreated its data. Rescan before retrying. \(out.prefix(300))") }
                    info = "Permanently deleted the selected item."
                }
                locked {
                    if var snap = snapshot {
                        for k in snap.items.indices where snap.items[k].path == item.path || snap.items[k].path.hasPrefix(item.path + "/") { snap.items[k].removed = true }
                        snapshot = snap; persist()
                    }
                }
            } else {
                let all = try simulatorList()
                guard let now = all.first(where: { $0["id"] as? String == t.target && $0["kind"] as? String == t.kind }), now["signature"] as? String == t.identity, now["enabled"] as? Bool == true else { throw AppError("The simulator inventory changed. Review it again.") }
                if t.kind == "runtime", all.contains(where: { $0["booted"] as? Bool == true }) { throw AppError("A simulator is running. Shut it down first.") }
                let args = t.kind == "runtime" ? ["simctl", "runtime", "delete", t.target] : ["simctl", "delete", t.target]
                let (rc, out) = try run("/usr/bin/xcrun", args, timeout: 180)
                guard rc == 0 else { throw AppError("Apple's tool did not complete the removal. \(out.prefix(400))") }
                info = "Apple's simulator tool completed the removal."
            }
        } catch { record("Cleanup needs attention", "\(t.name): \((error as? AppError)?.message ?? error.localizedDescription)"); throw error }
        _ = statfs(home, &s); let delta = Int64(s.f_bavail) * Int64(s.f_bsize) - before
        record(t.mode == "trash" ? "Moved to Trash" : "Removed item", "\(t.name). \(info)")
        return ["message": info + " Rescan to refresh the board.", "freeDelta": delta]
    }
}

final class HTTPServer {
    let store: Store; let listener: NWListener; let token: String; var port: UInt16 = 0
    let queue = DispatchQueue(label: "chipspace.network"); let requests = DispatchQueue(label: "chipspace.requests", attributes: .concurrent)
    var onReady: ((String) -> Void)?
    init(_ store: Store) throws {
        self.store = store; token = UUID().uuidString + UUID().uuidString
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state, let p = self.listener.port {
                self.port = p.rawValue; self.onReady?("http://127.0.0.1:\(self.port)/#\(self.token)")
            }
            if case .failed(let error) = state { fputs("Local server failed: \(error)\n", stderr); exit(1) }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    func accept(_ c: NWConnection) {
        c.start(queue: queue); var buffer = Data(); var handled = false
        queue.asyncAfter(deadline: .now() + 10) { if !handled { c.cancel() } }
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
                guard let self = self else { c.cancel(); return }
                if let bytes = bytes { buffer.append(bytes) }
                guard buffer.count <= 65536 else { handled = true; self.respond(c, 413, json(["error": "Request too large."])); return }
                if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)), let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) {
                    let lines = header.components(separatedBy: "\r\n"); let parts = (lines.first ?? "").split(separator: " ")
                    var headers: [String: String] = [:]; var invalid = false
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else { invalid = true; break }
                        let key = line[..<colon].lowercased(); if headers[key] != nil { invalid = true }
                        headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                    let rawLength = headers["content-length"] ?? "0"
                    guard !invalid, parts.count == 3, headers["transfer-encoding"] == nil, let length = Int(rawLength), length >= 0, length <= 32768 else { handled = true; self.respond(c, 400, json(["error": "Invalid HTTP request."])); return }
                    let start = boundary.upperBound
                    if buffer.count >= start + length {
                        handled = true; let body = Data(buffer[start..<(start + length)])
                        self.requests.async { self.route(c, method: String(parts[0]), path: String(parts[1]), headers: headers, body: body) }; return
                    }
                }
                if done || error != nil { c.cancel() } else { receive() }
            }
        }
        receive()
    }
    func route(_ c: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        let host = "127.0.0.1:\(port)"; let origin = "http://" + host
        guard headers["host"] == host, headers["origin"] == nil || headers["origin"] == origin else { respond(c, 403, json(["error": "Only this local app may access the server."])); return }
        if path.hasPrefix("/api/") {
            guard headers["authorization"] == "Bearer " + token else { respond(c, 401, json(["error": "Open the dashboard from the Chipspace menu-bar icon to reconnect."])); return }
            let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            do {
                switch (method, path) {
                case ("GET", "/api/state"): respond(c, 200, json(store.state()))
                case ("POST", "/api/scan"): try store.startScan(); respond(c, 202, json(["ok": true]))
                case ("GET", "/api/simulators"): respond(c, 200, json(["items": try store.simulatorList()]))
                case ("POST", "/api/prepare"): respond(c, 200, json(try store.prepare(value)))
                case ("POST", "/api/execute"): respond(c, 200, json(try store.execute(value)))
                case ("POST", "/api/reveal"):
                    let i = try store.find(value["id"] as? String ?? "")
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.path)]) }
                    respond(c, 200, json(["ok": true]))
                default: respond(c, 404, json(["error": "Not found."]))
                }
            } catch { respond(c, 409, json(["error": (error as? AppError)?.message ?? error.localizedDescription])) }
            return
        }
        let files = ["/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8"), "/icon.svg": ("icon.svg", "image/svg+xml")]
        guard method == "GET", let (file, mime) = files[path], let data = try? Data(contentsOf: store.resources.appendingPathComponent("Web").appendingPathComponent(file)) else { respond(c, 404, Data("Not found".utf8), mime: "text/plain"); return }
        respond(c, 200, data, mime: mime)
    }
    func respond(_ c: NWConnection, _ status: Int, _ data: Data, mime: String = "application/json") {
        let headers = "HTTP/1.1 \(status) Response\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n"
        c.send(content: Data(headers.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem?; var url = ""; let store: Store; let server: HTTPServer; let noBrowser: Bool
    init(store: Store, noBrowser: Bool) throws { self.store = store; self.noBrowser = noBrowser; self.server = try HTTPServer(store) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Chipspace")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Chipspace", action: #selector(openDashboard), keyEquivalent: ""); open.target = self; menu.addItem(open)
        let scan = NSMenuItem(title: "Scan storage", action: #selector(scanStorage), keyEquivalent: ""); scan.target = self; menu.addItem(scan)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Chipspace", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit); status?.menu = menu
        server.onReady = { [weak self] url in
            guard let self = self else { return }; self.url = url
            try? json(["url": url, "pid": ProcessInfo.processInfo.processIdentifier]).write(to: self.store.data.appendingPathComponent("connection.json"), options: .atomic)
            print("Chipspace is listening on 127.0.0.1:\(self.server.port)"); fflush(stdout)
            if !self.noBrowser { DispatchQueue.main.async { self.openDashboard() } }
        }
        server.start()
    }
    @objc func openDashboard() { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
    @objc func scanStorage() { try? store.startScan(); openDashboard() }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openDashboard(); return false }
    func applicationWillTerminate(_ notification: Notification) { store.scanProcess?.terminate(); server.listener.cancel(); try? fm.removeItem(at: store.data.appendingPathComponent("connection.json")) }
}

func selfTest() throws {
    let root = fm.temporaryDirectory.appendingPathComponent("chipspace-tests-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    let home = canonical(root.appendingPathComponent("home").path)
    let allowed = home + "/Library/Caches/pip"; let docs = home + "/Documents"
    try fm.createDirectory(atPath: allowed, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: docs, withIntermediateDirectories: true)
    func expectReject(_ p: String, _ sig: String) throws {
        do { try guardFile(p, home: home, expected: sig) } catch { return }; throw AppError("Guard accepted forbidden fixture: \(p)")
    }
    let sig = fingerprint(allowed)!; try guardFile(allowed, home: home, expected: sig)
    try expectReject(docs, fingerprint(docs)!); try expectReject(parent(allowed), fingerprint(parent(allowed))!)
    try fm.moveItem(atPath: allowed, toPath: allowed + "-old")
    try fm.createSymbolicLink(atPath: allowed, withDestinationPath: docs); try expectReject(allowed, sig)
    try fm.removeItem(atPath: allowed); try fm.createDirectory(atPath: allowed, withIntermediateDirectories: true); try expectReject(allowed, sig)
    try Data("preserve".utf8).write(to: URL(fileURLWithPath: docs + "/keep"))
    try fm.createSymbolicLink(atPath: allowed + "/link", withDestinationPath: docs)
    try guardFile(allowed, home: home, expected: fingerprint(allowed)!)
    let (rc, _) = try run("/bin/rm", ["-rfx", "--", allowed])
    guard rc == 0, fm.fileExists(atPath: docs + "/keep"), !fm.fileExists(atPath: allowed) else { throw AppError("Deletion boundary test failed") }
    // Run the production two-step confirmation flow against disposable data.
    try fm.createDirectory(atPath: allowed, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: URL(fileURLWithPath: allowed + "/test"))
    let store = try Store(home: home, resources: root, data: root.appendingPathComponent("state"))
    let item = Item(id: "fixture", path: allowed, name: "Disposable cache", bytes: 4096, complete: true, action: "conditional", explanation: "Fixture", advice: "Disposable test data only", identity: fingerprint(allowed)!, parentID: nil, category: "caches")
    store.snapshot = Snapshot(home: home, date: 0, reportPath: "", items: [item], errors: "")
    var t = try store.prepare(["id": "fixture", "mode": "delete"])
    do { _ = try store.execute(["ticket": t["ticket"]!, "confirmation": "DELETE", "closed": false]); throw AppError("Missing confirmation was accepted") } catch let e as AppError { if e.message == "Missing confirmation was accepted" { throw e } }
    guard fm.fileExists(atPath: allowed) else { throw AppError("Cancelled cleanup deleted data") }
    t = try store.prepare(["id": "fixture", "mode": "delete"])
    let key = t["ticket"]!
    _ = try store.execute(["ticket": key, "confirmation": "DELETE", "closed": true])
    guard !fm.fileExists(atPath: allowed), fm.fileExists(atPath: docs + "/keep") else { throw AppError("Confirmed cleanup failed") }
    do { _ = try store.execute(["ticket": key, "confirmation": "DELETE", "closed": true]); throw AppError("Ticket replay was accepted") } catch let e as AppError { if e.message == "Ticket replay was accepted" { throw e } }
    print("PASS: allowlist, protected paths, replaced identities, symlinks, deletion boundaries, confirmation rejection, confirmed cleanup, and single-use tickets.")
}

do {
    umask(0o077)
    guard getuid() != 0 else { throw AppError("Run Chipspace as your normal user, without sudo.") }
    if CommandLine.arguments.contains("--self-test") { try selfTest(); exit(0) }
    func arg(_ flag: String) -> String? { guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }; return CommandLine.arguments[i + 1] }
    let home = canonical(fm.homeDirectoryForCurrentUser.path)
    let resources = URL(fileURLWithPath: arg("--resources") ?? Bundle.main.resourcePath ?? ".")
    let data = URL(fileURLWithPath: arg("--data-dir") ?? home + "/Library/Application Support/Chipspace")
    let store = try Store(home: home, resources: resources, data: data)
    if let report = arg("--import-report") { try store.importReport(URL(fileURLWithPath: report)) }
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let delegate = try AppDelegate(store: store, noBrowser: CommandLine.arguments.contains("--no-browser"))
    app.delegate = delegate; withExtendedLifetime(delegate) { app.run() }
} catch { fputs("Chipspace: \((error as? AppError)?.message ?? error.localizedDescription)\n", stderr); exit(1) }
