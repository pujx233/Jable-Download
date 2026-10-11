import AppKit
import Foundation
import Darwin
import IOKit.pwr_mgt

@MainActor
final class StoreFixture {
    let root: URL
    let support: URL
    let runtime: URL
    let defaults: UserDefaults
    let suite: String

    init(worker: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jable-store-test-\(UUID().uuidString)")
        support = root.appendingPathComponent("support")
        runtime = root.appendingPathComponent("runtime")
        suite = "local.jable.desktop.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("_internal/tools"), withIntermediateDirectories: true)
        defaults.set(root.appendingPathComponent("output").path, forKey: "output")
        if worker {
            let script = """
            #!/bin/sh
            trap 'printf \'%s\\n\' \'{"event":"cancelled"}\'; exit 130' TERM INT
            printf '%s\\n' "$@" > "\(root.path)/arguments.txt"
            printf '%s\\n' '{"event":"phase","phase":"下载视频"}'
            /bin/sleep 0.15
            case "$2" in
              */fail-001/) printf '%s\\n' '{"event":"error","detail":"fixture failure"}'; exit 1;;
            esac
            printf '%s' '{"event":"pro'
            printf '%s\\n' 'gress","progress":0.9,"completed":10,"total":10,"bytes_per_second":1000}'
            printf '%s\\n' '{"event":"done","progress":1}'
            """
            let executable = runtime.appendingPathComponent("jable-worker")
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let ffmpeg = runtime.appendingPathComponent("_internal/tools/ffmpeg")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: ffmpeg)
        }
    }

    func store() -> DownloadStore {
        DownloadStore(supportDirectory: support, defaults: defaults, runtimeDirectory: runtime)
    }

    func clean() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
}

enum TestFailure: Error { case failed(String) }

@main
struct DesktopTests {
    @MainActor
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.failed(message) }
    }

    @MainActor
    static func waitForIdle(_ store: DownloadStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.activeID != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(store.activeID == nil, "worker did not finish")
    }

    @MainActor
    static func check(_ name: String, _ action: () async throws -> Void) async throws {
        try await action()
        print("PASS \(name)")
    }

    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }

    @MainActor
    static func run() async throws {
        _ = NSApplication.shared
        try await check("URL normalization") {
            try require(DownloadStore.canonical("HTTPS://WWW.JABLE.TV/videos/START-498/?x=1")?.1 == "START-498", "valid URL")
            for value in ["https://jable.tv.evil.test/videos/a/", "https://jable.tv/actors/a/", "https://user:password@jable.tv/videos/a/", "https://jable.tv:8080/videos/a/"] {
                try require(DownloadStore.canonical(value) == nil, "invalid URL accepted")
            }
        }
        try await check("Batch input, duplicate detection, invalid input retained, queue completion") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            let store = fixture.store()
            store.draft = "https://jable.tv/videos/client-001/\nhttps://www.jable.tv/videos/CLIENT-001/\nnot-a-link\nhttps://jable.tv/videos/client-002/"
            try require(store.addLinks() == 2, "wrong task count")
            try require(store.draft == "not-a-link", "invalid input was lost")
            try await waitForIdle(store)
            try require(store.jobs.allSatisfy { $0.state == .completed && $0.progress == 1 }, "queue did not finish")
            try require(!store.autoRun && !store.canResume && !store.canPause, "completed queue controls still active")
            store.draft = "https://jable.tv/videos/client-001/"
            try require(store.addLinks() == 0 && store.jobs.count == 2, "duplicate task accepted")
        }
        try await check("Preferences passed to worker") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            let store = fixture.store()
            store.workers = 4
            store.showBrowser = true
            store.draft = "https://jable.tv/videos/client-001/"
            store.addLinks()
            try await waitForIdle(store)
            let args = try String(contentsOf: fixture.root.appendingPathComponent("arguments.txt"), encoding: .utf8)
            try require(args.contains("--workers\n4\n") && args.contains("--show-browser"), "settings not applied")
            let restored = fixture.store()
            try require(restored.workers == 4 && restored.showBrowser, "settings not persisted")
        }
        try await check("Pause and resume serial queue") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            let store = fixture.store()
            store.draft = "https://jable.tv/videos/client-001/\nhttps://jable.tv/videos/client-002/"
            store.addLinks()
            store.pauseAll()
            try await waitForIdle(store)
            try require(store.jobs[0].state == .paused && store.jobs[1].state == .queued, "pause advanced queue")
            try require(!store.autoRun && store.canResume && !store.canPause, "paused queue controls")
            store.resumeAll()
            try await waitForIdle(store)
            try require(store.jobs.allSatisfy { $0.state == .completed }, "resume incomplete")
        }
        try await check("Failed job does not prevent next download") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            let store = fixture.store()
            store.draft = "https://jable.tv/videos/fail-001/\nhttps://jable.tv/videos/client-002/"
            store.addLinks()
            try await waitForIdle(store)
            try require(store.jobs[0].state == .failed && store.jobs[1].state == .completed, "failure stalled queue")
            try require(store.logs.contains { $0.message.contains("fixture failure") }, "failure not logged")
        }
        try await check("Active task cannot be removed") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            let store = fixture.store()
            store.draft = "https://jable.tv/videos/client-001/"
            store.addLinks()
            let id = store.jobs[0].id
            store.remove(id)
            try require(store.jobs.count == 1, "removed running task")
            store.pauseAll()
            try await waitForIdle(store)
            store.remove(id)
            try require(store.jobs.isEmpty, "could not remove paused task")
        }
        try await check("Running jobs restore paused without automatic downloads") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            var job = DownloadJob(url: "https://jable.tv/videos/client-001/", code: "CLIENT-001", destination: fixture.root.path)
            job.state = .running
            job.progress = 0.6
            job.detail = "old connection speed"
            try JSONEncoder().encode([job]).write(to: fixture.support.appendingPathComponent("queue.json"))
            let store = fixture.store()
            try require(store.jobs[0].state == .paused && store.jobs[0].detail.isEmpty, "stale running state")
            try require(store.activeID == nil && !store.autoRun, "unexpected automatic download")
        }
        try await check("Unreadable queue is backed up before saving") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            let original = Data("unreadable queue fixture".utf8)
            let path = fixture.support.appendingPathComponent("queue.json")
            try original.write(to: path)
            let store = fixture.store()
            store.save()
            let backups = try FileManager.default.contentsOfDirectory(at: fixture.support, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("queue-unreadable-") }
            try require(backups.count == 1, "missing recovery copy")
            let recovered = try Data(contentsOf: backups[0])
            try require(recovered == original, "recovery copy altered")
            let saved = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: path))
            try require(saved.isEmpty, "fresh queue invalid")
        }
        try await check("Missing runtime shows failure and stops queue") {
            let fixture = try StoreFixture(worker: false)
            defer { try? fixture.clean() }
            let store = fixture.store()
            store.draft = "https://jable.tv/videos/client-001/"
            store.addLinks()
            try require(store.jobs[0].state == .failed && !store.jobs[0].detail.isEmpty, "missing runtime not reported")
            try require(!store.autoRun && store.activeID == nil, "invalid runtime started")
        }
        try await check("Download prevents idle sleep and releases the assertion when paused") {
            let fixture = try StoreFixture()
            defer { try? fixture.clean() }
            func preventsIdleSleep() throws -> Bool {
                var copied: Unmanaged<CFDictionary>?
                let status = IOPMCopyAssertionsByProcess(&copied)
                guard status == kIOReturnSuccess, let dictionary = copied?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
                    throw TestFailure.failed("could not read power assertions")
                }
                let assertions = dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
                return assertions.contains {
                    ($0[kIOPMAssertionTypeKey as String] as? String) == (kIOPMAssertionTypePreventUserIdleSystemSleep as String)
                }
            }
            let store = fixture.store()
            let initial = try preventsIdleSleep()
            try require(!initial, "unexpected initial assertion")
            store.draft = "https://jable.tv/videos/client-001/"
            store.addLinks()
            let active = try preventsIdleSleep()
            store.pauseAll()
            try await waitForIdle(store)
            let paused = try preventsIdleSleep()
            try require(active && !paused, "download assertion was not paired with worker lifetime")
        }
        try await check("Placeholder and input share native glyph placement") {
            let editor = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 88), textContainer: nil)
            let window = NSWindow(contentRect: editor.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = editor
            @MainActor func inkBounds() throws -> NSRect {
                let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds)!
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                var left = bitmap.pixelsWide, top = bitmap.pixelsHigh, right = -1, bottom = -1
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                        left = min(left, x); right = max(right, x)
                        top = min(top, y); bottom = max(bottom, y)
                    }
                }
                try require(right >= left && bottom >= top, "text was not rendered")
                return NSRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
            }
            let placeholder = try inkBounds()
            editor.string = "粘贴影片链接"
            editor.layoutManager?.ensureLayout(for: editor.textContainer!)
            let typed = try inkBounds()
            try require(abs(placeholder.minX - typed.minX) <= 1 && abs(placeholder.minY - typed.minY) <= 1, "placeholder position differs from text")
            try require(abs(placeholder.width - typed.width) <= 1 && abs(placeholder.height - typed.height) <= 1, "placeholder font differs from text")
            print("Native text bounds: placeholder \(placeholder), typed \(typed)")
            window.close()
        }
        print("11 desktop tests passed")
    }
}
