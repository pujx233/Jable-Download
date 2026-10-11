import AppKit
import SwiftUI

enum AppStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.43, blue: 0.60, alpha: 1)
            : NSColor(srgbRed: 0.79, green: 0.15, blue: 0.36, alpha: 1)
    })
}

enum JobState: String, Codable {
    case queued, running, paused, failed, completed
    var label: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .failed: return "失败"
        case .completed: return "已完成"
        }
    }
    var color: Color {
        switch self {
        case .running: return AppStyle.accent
        case .failed: return .orange
        case .completed: return .green
        default: return .secondary
        }
    }
}

struct DownloadJob: Identifiable, Codable {
    var id = UUID()
    var url: String
    var code: String
    var destination: String
    var title = ""
    var state = JobState.queued
    var progress = 0.0
    var phase = "等待开始"
    var detail = ""
    var folder: String { (destination as NSString).appendingPathComponent(code) }
}

struct RunLog: Identifiable {
    let id = UUID()
    let time: String
    let message: String
}

@MainActor
final class DownloadStore: ObservableObject {
    static let workerOptions = [1, 2, 4, 8, 12, 16]
    @Published var jobs: [DownloadJob] = []
    @Published var draft = ""
    @Published var notice = ""
    @Published var logs: [RunLog] = []
    @Published var autoRun = false
    @Published var activeID: UUID?
    @Published var output: String {
        didSet { preferences.set(output, forKey: "output") }
    }
    @Published var showBrowser: Bool {
        didSet { preferences.set(showBrowser, forKey: "showBrowser") }
    }
    @Published var workers: Int {
        didSet { preferences.set(workers, forKey: "workers") }
    }
    private var process: Process?
    private var downloadActivity: NSObjectProtocol?
    private var pausing: Set<UUID> = []
    private var quitting = false
    private var lastSave = Date.distantPast
    private let stateFile: URL
    private let preferences: UserDefaults
    private let runtime: URL?
    private var canSave = true

    init(supportDirectory: URL? = nil, defaults: UserDefaults = .standard, runtimeDirectory: URL? = nil) {
        preferences = defaults
        runtime = runtimeDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("worker")
        output = defaults.string(forKey: "output") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Jable").path
        showBrowser = defaults.bool(forKey: "showBrowser")
        let savedWorkers = defaults.integer(forKey: "workers")
        workers = Self.workerOptions.contains(savedWorkers) ? savedWorkers : 8
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jable Desktop", isDirectory: true)
        stateFile = support.appendingPathComponent("queue.json")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: stateFile.path) {
                jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: stateFile)).map {
                    var job = $0
                    if job.state == .running {
                        job.state = .paused
                        job.phase = "等待继续"
                        job.detail = ""
                    }
                    job.progress = min(1, max(0, job.progress))
                    return job
                }
            }
        } catch {
            // Keep unreadable records recoverable before starting a fresh queue.
            if FileManager.default.fileExists(atPath: stateFile.path) {
                let backup = support.appendingPathComponent("queue-unreadable-\(UUID().uuidString).json")
                do {
                    try FileManager.default.copyItem(at: stateFile, to: backup)
                    notice = "任务记录无法读取，原记录已备份。"
                } catch {
                    canSave = false
                    notice = "无法读取任务记录：\(error.localizedDescription)"
                }
            } else {
                canSave = false
                notice = "无法打开任务目录：\(error.localizedDescription)"
            }
        }
    }

    func save() {
        guard canSave else { return }
        do {
            try JSONEncoder().encode(jobs).write(to: stateFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
            lastSave = Date()
        } catch { notice = "无法保存任务记录：\(error.localizedDescription)" }
    }

    static func canonical(_ value: String) -> (String, String)? {
        guard let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              ["jable.tv", "www.jable.tv"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              let range = parts.path.range(of: "^/videos/[a-zA-Z0-9][a-zA-Z0-9-]{0,79}/?$", options: .regularExpression),
              range == parts.path.startIndex..<parts.path.endIndex else { return nil }
        let slug = parts.path.split(separator: "/")[1].lowercased()
        return ("https://jable.tv/videos/\(slug)/", slug.uppercased())
    }

    func pasteLinks() {
        if let text = NSPasteboard.general.string(forType: .string) {
            draft = draft.isEmpty ? text : draft + "\n" + text
        }
    }

    @discardableResult
    func addLinks() -> Int {
        guard canSave else { return 0 }
        let values = draft.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var invalid: [String] = []
        var duplicates = 0, added = 0
        for value in values {
            let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "[](),，<>"))
            guard let (url, code) = Self.canonical(clean) else { invalid.append(value); continue }
            if jobs.contains(where: { $0.url == url && $0.destination == output }) {
                duplicates += 1
                continue
            }
            jobs.append(DownloadJob(url: url, code: code, destination: output))
            added += 1
        }
        guard added > 0 else {
            notice = duplicates > 0 && invalid.isEmpty ? "链接已在队列中。" : "请输入 Jable 影片链接。"
            return 0
        }
        draft = invalid.joined(separator: "\n")
        notice = invalid.isEmpty ? "" : "\(invalid.count) 条链接无法识别，请检查输入框。"
        autoRun = true
        save()
        startNext()
        return added
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "选择下载保存目录"
        panel.prompt = "选择目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: output)
        if panel.runModal() == .OK, let url = panel.url {
            output = url.path
            notice = ""
        }
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(url) }
        else { notice = "目录还不存在。" }
    }

    var canResume: Bool {
        activeID.map(isPausing) != true && jobs.contains { $0.state == .paused || ($0.state == .queued && !autoRun) }
    }
    var canPause: Bool { autoRun || activeID != nil }
    func isPausing(_ id: UUID) -> Bool { pausing.contains(id) }

    func resumeAll() {
        guard canResume else { return }
        for index in jobs.indices where jobs[index].state == .paused {
            jobs[index].state = .queued
            jobs[index].phase = "等待继续"
        }
        autoRun = true
        save()
        startNext()
    }

    func pauseAll() {
        autoRun = false
        if let id = activeID { pause(id) }
        save()
    }

    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              [.queued, .running].contains(jobs[index].state), !pausing.contains(id) else { return }
        if activeID == id {
            pausing.insert(id)
            jobs[index].phase = "正在暂停"
            jobs[index].detail = ""
            if process?.isRunning == true { process?.terminate() }
        } else {
            jobs[index].state = .paused
            jobs[index].phase = "等待继续"
            jobs[index].detail = ""
        }
        save()
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), activeID != id else { return }
        jobs[index].state = .queued
        jobs[index].phase = "等待继续"
        jobs[index].detail = ""
        autoRun = true
        save()
        startNext()
    }

    func remove(_ id: UUID) {
        guard activeID != id else { return }
        jobs.removeAll { $0.id == id }
        save()
    }

    private func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append(RunLog(time: formatter.string(from: Date()), message: text))
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }

    private func startNext() {
        guard autoRun, !quitting, process == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.state == .queued }) else {
            autoRun = false
            return
        }
        let job = jobs[index]
        let executable = runtime?.appendingPathComponent("jable-worker")
        let ffmpeg = runtime?.appendingPathComponent("_internal/tools/ffmpeg")
        guard let executable, let ffmpeg,
              FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            jobs[index].state = .failed
            jobs[index].phase = "无法开始下载"
            jobs[index].detail = "下载组件缺失，请重新安装客户端。"
            log("\(job.code) · 下载组件缺失")
            autoRun = false
            save()
            return
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--url", job.url, "--output", job.destination, "--ffmpeg", ffmpeg.path,
                           "--workers", String(workers)] + (showBrowser ? ["--show-browser"] : [])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        child.environment = environment
        let outputPipe = Pipe(), errorPipe = Pipe()
        child.standardOutput = outputPipe
        child.standardError = errorPipe
        let readers = DispatchGroup()
        observe(outputPipe.fileHandleForReading, id: job.id, isError: false, group: readers)
        observe(errorPipe.fileHandleForReading, id: job.id, isError: true, group: readers)
        child.terminationHandler = { [weak self] terminated in
            readers.notify(queue: .main) {
                Task { @MainActor in self?.finished(job.id, status: terminated.terminationStatus) }
            }
        }
        jobs[index].state = .running
        jobs[index].phase = "启动下载"
        jobs[index].detail = ""
        activeID = job.id
        process = child
        downloadActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "下载影片")
        do {
            try child.run()
            log("\(job.code) · 开始")
            save()
        } catch {
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            process = nil
            activeID = nil
            endDownloadActivity()
            jobs[index].state = .failed
            jobs[index].phase = "无法开始下载"
            jobs[index].detail = error.localizedDescription
            log("\(job.code) · \(error.localizedDescription)")
            autoRun = false
            save()
        }
    }

    nonisolated private func observe(_ handle: FileHandle, id: UUID, isError: Bool, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? handle.close(); group.leave() }
            var pending = Data()
            // Deliver pipe output as it arrives, rather than filling a read buffer.
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<end], as: UTF8.self)
                    pending.removeSubrange(...end)
                    DispatchQueue.main.async { self?.handle(line, id: id, isError: isError) }
                }
            }
            if !pending.isEmpty {
                let line = String(decoding: pending, as: UTF8.self)
                DispatchQueue.main.async { self?.handle(line, id: id, isError: isError) }
            }
        }
    }

    private func handle(_ line: String, id: UUID, isError: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if isError {
            if !line.isEmpty { log("组件提示：" + String(line.prefix(220))) }
            return
        }
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["event"] as? String else { return }
        if let progress = event["progress"] as? Double { jobs[index].progress = min(1, max(0, progress)) }
        if let phase = event["phase"] as? String, !pausing.contains(id) { jobs[index].phase = phase }
        if let detail = event["detail"] as? String { jobs[index].detail = detail }
        switch kind {
        case "metadata":
            jobs[index].title = event["title"] as? String ?? ""
        case "phase":
            log("\(jobs[index].code) · \(jobs[index].phase)")
        case "progress":
            if !pausing.contains(id), let done = event["completed"] as? Int, let total = event["total"] as? Int {
                let speed = event["bytes_per_second"] as? Double ?? 0
                let rate = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
                jobs[index].detail = "\(done) / \(total) 片段 · \(rate)/s"
            }
        case "done":
            jobs[index].state = .completed
            jobs[index].progress = 1
            jobs[index].phase = ""
            jobs[index].detail = ""
            log("\(jobs[index].code) · 完成")
        case "cancelled":
            jobs[index].state = .paused
            jobs[index].phase = "等待继续"
            jobs[index].detail = ""
            log("\(jobs[index].code) · 已暂停")
        case "error":
            jobs[index].state = .failed
            jobs[index].phase = "下载未完成"
            log("\(jobs[index].code) · \(jobs[index].detail)")
        default: break
        }
        if kind != "progress" || Date().timeIntervalSince(lastSave) > 1 { save() }
    }

    private func finished(_ id: UUID, status: Int32) {
        guard activeID == id else { return }
        if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running {
            if pausing.contains(id) || status == 130 {
                jobs[index].state = .paused
                jobs[index].phase = "等待继续"
            } else {
                jobs[index].state = .failed
                jobs[index].phase = "下载未完成"
                jobs[index].detail = "下载组件意外退出（\(status)）"
                log("\(jobs[index].code) · \(jobs[index].detail)")
            }
        }
        pausing.remove(id)
        endDownloadActivity()
        process = nil
        activeID = nil
        save()
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        else { startNext() }
    }

    private func endDownloadActivity() {
        if let downloadActivity {
            ProcessInfo.processInfo.endActivity(downloadActivity)
            self.downloadActivity = nil
        }
    }

    func requestQuit() -> NSApplication.TerminateReply {
        guard activeID != nil else { save(); return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "暂停下载并退出？"
        alert.informativeText = ""
        alert.addButton(withTitle: "暂停并退出")
        alert.addButton(withTitle: "继续下载")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard activeID != nil else { save(); return .terminateNow }
        quitting = true
        pauseAll()
        return .terminateLater
    }
}
