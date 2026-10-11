import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: DownloadStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.store?.requestQuit() ?? .terminateNow
    }
}

enum QueueFilter: String, CaseIterable {
    case all = "全部任务", unfinished = "未完成", completed = "已完成"
    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .unfinished: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        }
    }
}

@MainActor
final class QueuePresentation: ObservableObject {
    @Published var filter = QueueFilter.all
    @Published var editorFocused = false
}

struct ContentView: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var presentation = QueuePresentation()
    private var filtered: [DownloadJob] {
        store.jobs.filter { presentation.filter == .all || (presentation.filter == .completed ? $0.state == .completed : $0.state != .completed) }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        composer
                        destination
                        queue
                    }.padding(24)
                }
                noticeBanner
            }
        }
        .frame(minWidth: 840, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(AppStyle.accent)
        .onAppear { AppDelegate.store = store }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                if let iconURL = Bundle.main.url(forResource: "JableBrand", withExtension: "png"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .scaledToFit().frame(width: 38, height: 38)
                        .accessibilityLabel("Jable")
                }
                Text("Jable").font(.system(size: 22, weight: .bold, design: .rounded))
            }.padding(.top, 10)
            VStack(spacing: 5) {
                ForEach(QueueFilter.allCases, id: \.self) { item in
                    Button { presentation.filter = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item.rawValue)
                            Spacer()
                            Text("\(count(item))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(presentation.filter == item ? AppStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                        .foregroundStyle(presentation.filter == item ? AppStyle.accent : .primary)
                    }.buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.rawValue)
                        .accessibilityValue("\(count(item)) 个任务")
                        .accessibilityAddTraits(presentation.filter == item ? [.isButton, .isSelected] : [.isButton])
                        .accessibilityRemoveTraits(presentation.filter == item ? [] : [.isSelected])
                }
            }
            Spacer()
            VStack(spacing: 4) {
                Button { openWindow(id: "logs") } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft").frame(width: 18)
                        Text("运行记录")
                        Spacer()
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                SettingsLink {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape").frame(width: 18)
                        Text("设置")
                        Spacer()
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(16).frame(width: 180)
            .background(.thinMaterial)
    }

    private func count(_ item: QueueFilter) -> Int {
        store.jobs.filter { item == .all || (item == .completed ? $0.state == .completed : $0.state != .completed) }.count
    }

    private var header: some View {
        HStack {
            Text("下载").font(.system(size: 25, weight: .bold, design: .rounded))
            Spacer()
            if store.activeID != nil {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(store.activeID.map(store.isPausing) == true ? "正在暂停" : "下载中").font(.system(size: 12))
                }.padding(.horizontal, 10).padding(.vertical, 7).background(.green.opacity(0.08), in: Capsule())
            }
        }.padding(.horizontal, 24).padding(.top, 27).padding(.bottom, 4)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("添加影片", systemImage: "link").font(.system(size: 14, weight: .semibold))
            }
            LinkEditor(text: $store.draft) { focused in
                DispatchQueue.main.async { presentation.editorFocused = focused }
            }
            .frame(height: 88)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                presentation.editorFocused ? AppStyle.accent.opacity(0.8) : Color(nsColor: .separatorColor),
                lineWidth: presentation.editorFocused ? 1.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            HStack {
                Button { store.pasteLinks() } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                Spacer()
                Button {
                    if store.addLinks() > 0 { presentation.filter = .all }
                } label: { Label("开始下载", systemImage: "arrow.down") }
                    .buttonStyle(.borderedProminent).disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }.controlSize(.regular)
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var destination: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("保存位置").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(store.output.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(store.output)
            }
            Spacer(minLength: 5)
            Button("更改…") { store.chooseOutput() }
            Button { store.reveal(store.output) } label: { Image(systemName: "arrow.up.right.square") }
                .help("在访达中打开").accessibilityLabel("打开保存位置")
        }.padding(.horizontal, 4)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(presentation.filter.rawValue).font(.system(size: 14, weight: .semibold))
                Text("\(filtered.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if store.jobs.contains(where: { $0.state != .completed }) {
                    Button { store.resumeAll() } label: { Label("全部继续", systemImage: "play.fill") }.disabled(!store.canResume)
                    Button { store.pauseAll() } label: { Label("全部暂停", systemImage: "pause.fill") }
                        .disabled(!store.canPause || store.activeID.map(store.isPausing) == true)
                }
            }.controlSize(.small)
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: presentation.filter.icon).font(.system(size: 31, weight: .light)).foregroundStyle(.tertiary)
                    Text(emptyTitle).font(.system(size: 14)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    .background(.quaternary.opacity(0.17), in: RoundedRectangle(cornerRadius: 13))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { job in JobRow(job: job, store: store) }
                }
            }
        }
    }

    private var emptyTitle: String {
        switch presentation.filter {
        case .all: return "还没有下载任务"
        case .unfinished: return "没有未完成的任务"
        case .completed: return "还没有下载完成的影片"
        }
    }

    private var noticeBanner: some View {
        VStack(spacing: 0) {
            if !store.notice.isEmpty {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(store.notice).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button { store.notice = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
    }
}

struct JobRow: View {
    let job: DownloadJob
    @ObservedObject var store: DownloadStore
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: job.state == .completed ? "checkmark.circle.fill" : "film")
                .font(.system(size: 23, weight: .light)).foregroundStyle(job.state.color)
                .frame(width: 43, height: 43).background(job.state.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.code).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text(store.isPausing(job.id) ? "正在暂停" : job.state.label).font(.system(size: 12, weight: .medium)).foregroundStyle(job.state.color)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(job.state.color.opacity(0.08), in: Capsule())
                    Spacer()
                    if [.paused, .failed].contains(job.state) {
                        Button(job.state == .failed ? "重试" : "继续") { store.retry(job.id) }
                            .disabled(store.activeID == job.id)
                    } else if [.queued, .running].contains(job.state) {
                        Button { store.pause(job.id) } label: { Image(systemName: "pause.fill") }
                            .help("暂停下载").accessibilityLabel("暂停 \(job.code)")
                            .disabled(store.isPausing(job.id))
                    }
                    Button { store.reveal(job.folder) } label: { Image(systemName: "folder") }
                        .help("打开影片目录").accessibilityLabel("打开 \(job.code) 目录")
                    Button { store.remove(job.id) } label: { Image(systemName: "xmark") }
                        .help("移除任务").accessibilityLabel("移除 \(job.code)").disabled(store.activeID == job.id)
                }.buttonStyle(.borderless).controlSize(.small)
                if !job.title.isEmpty {
                    Text(job.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                }
                if job.state != .completed {
                    ProgressView(value: job.progress).progressViewStyle(.linear)
                }
                if job.state != .completed {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            if job.state == .running, !store.isPausing(job.id) {
                                Text(job.phase).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if !job.detail.isEmpty {
                                Text(job.detail).font(.system(size: 12))
                                    .foregroundStyle(job.state == .failed ? .orange : .secondary).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Text("\(Int(job.progress * 100))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(15).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }
}

@MainActor
final class LogPresentation: ObservableObject {
    @Published var autoScroll = true
}

struct LogView: View {
    @ObservedObject var store: DownloadStore
    @StateObject private var presentation = LogPresentation()

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Toggle("自动滚动", isOn: $presentation.autoScroll).toggleStyle(.checkbox)
                Spacer()
                Button {
                    let text = store.logs.map { "\($0.time)  \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("复制", systemImage: "doc.on.doc") }
                .disabled(store.logs.isEmpty).help("复制全部运行记录")
            }.controlSize(.regular)
            Group {
                if store.logs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.alignleft").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                        Text("暂时没有运行记录").font(.system(size: 13, weight: .medium))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(store.logs) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                                        Text(entry.time).font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
                                        Text(entry.message).font(.system(size: 13)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(.horizontal, 16).padding(.vertical, 11).id(entry.id)
                                    Divider().padding(.horizontal, 16)
                                }
                            }
                        }
                        .onAppear {
                            if let id = store.logs.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                        }
                        .onChange(of: store.logs.last?.id) { _, id in
                            if presentation.autoScroll, let id { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
        }.padding(20).frame(minWidth: 620, minHeight: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(AppStyle.accent)
    }
}

struct ConcurrencyPicker: NSViewRepresentable {
    @Binding var workers: Int

    func makeCoordinator() -> Coordinator { Coordinator(workers: $workers) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13)
        control.bezelStyle = .rounded
        control.alignment = .left
        control.menu?.autoenablesItems = false
        for number in DownloadStore.workerOptions {
            control.addItem(withTitle: number == 8 ? "8（默认）" : "\(number)")
            control.lastItem?.tag = number
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectConcurrency(_:))
        control.setAccessibilityLabel("下载并发")
        control.setAccessibilityIdentifier("download-concurrency")
        return control
    }

    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.workers = $workers
        control.selectItem(withTag: workers)
    }

    final class Coordinator: NSObject {
        var workers: Binding<Int>
        init(workers: Binding<Int>) { self.workers = workers }

        @objc func selectConcurrency(_ sender: NSPopUpButton) {
            if let number = sender.selectedItem?.tag { workers.wrappedValue = number }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        Form {
            LabeledContent("保存位置") {
                HStack(spacing: 12) {
                    Text(store.output.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(store.output)
                    Button("更改…") { store.chooseOutput() }
                }
            }
            .accessibilityElement(children: .contain)
            LabeledContent("下载并发") {
                ConcurrencyPicker(workers: $store.workers)
                    .frame(width: 128, height: 26)
            }
            .accessibilityElement(children: .contain)
            Toggle("遇到验证时打开 Chrome", isOn: $store.showBrowser).toggleStyle(.switch)
        }
        .formStyle(.grouped)
        .tint(AppStyle.accent)
        .frame(width: 540, height: 180)
    }
}

@main
struct JableDownloadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = DownloadStore()
    var body: some Scene {
        Window("Jable Download", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 940, height: 670)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .pasteboard) {
                Button("粘贴影片链接") { store.pasteLinks() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView(store: store)
        }
        Window("运行记录", id: "logs") {
            LogView(store: store)
        }.defaultSize(width: 720, height: 400)
    }
}
