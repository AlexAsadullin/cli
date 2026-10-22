import AppKit
import SwiftUI

let accent = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757

@main
struct ClaudeSchedulerApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Claude Scheduler", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 520, minHeight: 380)
        }
        .defaultSize(width: 585, height: 400)   // the size of a default Terminal window
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        WindowGroup("Logs", id: "logs", for: String.self) { $taskId in
            if let taskId {
                LogsView(taskId: taskId).environmentObject(store)
            }
        }
        .defaultSize(width: 760, height: 520)
    }
}

struct LogsView: View {
    @EnvironmentObject var store: Store
    let taskId: String
    @State private var tab = "conversation"
    @State private var text = ""
    @State private var follow = true
    @State private var lastModified: Date?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var task: ScheduledTask? { store.tasks.first { $0.id == taskId } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    Text("Conversation").tag("conversation")
                    Text("Run log").tag("run")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Keep scrolled to the newest lines")
                Spacer()
                if let task, let target = store.tmuxTarget(for: task) {
                    Button { store.openTerminal(attachedTo: target) } label: {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .help("Opens Terminal attached to tmux session \(target)")
                }
                if let task {
                    Button { NSWorkspace.shared.open(store.taskFolder(for: task)) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show task files")
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: text) { _, _ in if follow { proxy.scrollTo("bottom", anchor: .bottomLeading) } }
                .onChange(of: follow) { _, on in if on { proxy.scrollTo("bottom", anchor: .bottomLeading) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottomLeading) }
            }
        }
        .navigationTitle(task.map { "Logs — " + $0.prompt.replacingOccurrences(of: "\n", with: " ").prefix(50) } ?? "Logs")
        .onAppear(perform: reload)
        .onChange(of: tab) { _, _ in text = ""; lastModified = nil; reload() }
        .onReceive(timer) { _ in reload() }
    }

    private func reload() {
        guard let task else { text = "This task was removed."; return }
        if tab == "conversation" {
            guard let url = store.transcriptURL(for: task) else {
                text = "No transcript yet. It appears once the task has started a Claude session."
                return
            }
            // Parsing a multi-MB transcript every 2s is wasteful: only re-read when the file changed.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard modified != lastModified || text.isEmpty else { return }
            lastModified = modified
            Task.detached {
                let conversation = Store.conversation(from: url)
                await MainActor.run { if tab == "conversation" { text = conversation } }
            }
        } else {
            let log = store.runLog(for: task)
            if log != text { text = log }
        }
    }
}

/// The bundled Lucide clock, stroked in the accent color.
let clockImage: NSImage = {
    guard let url = Bundle.main.url(forResource: "clock", withExtension: "svg"),
          let svg = try? String(contentsOf: url, encoding: .utf8),
          let image = NSImage(data: Data(svg.replacingOccurrences(of: "currentColor", with: "#D97757").utf8))
    else { return NSImage(systemSymbolName: "clock", accessibilityDescription: nil)! }
    return image
}()

let chooseFolderTag = "\u{0}choose"

private func folderLabel(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    return "\(name) — \(parent)"
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var folder = ""
    @State private var sessionId = ""          // "" = new session
    @State private var prompt = ""
    @State private var day = Date()
    @State private var time = Date().addingTimeInterval(120).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    @State private var showCalendar = false
    @State private var error: String?

    /// The chosen day at the typed HH:mm, or nil if the time doesn't parse.
    private var fireDate: Date? {
        let parts = time.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private var folderSessions: [SessionInfo] { store.sessions.filter { $0.folder == folder } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            form
            Divider()
            taskList
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .ignoresSafeArea(.container, edges: .top)
        .tint(accent)
        .onChange(of: store.sessions) { _, _ in pickDefaults() }
        .onChange(of: folder) { old, new in
            if new == chooseFolderTag {
                folder = old
                chooseFolder()
            } else {
                sessionId = folderSessions.first?.id ?? ""
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: clockImage).resizable().frame(width: 15, height: 15)
            Text("Claude Scheduler").font(.system(size: 13, weight: .semibold))
            Spacer()
            LimitsBadge()
            Button { store.reloadSessions() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload sessions")
        }
        .padding(.leading, 62)   // sits in the title bar, right of the traffic-light buttons
        .frame(height: 30)
        .padding(.top, 1)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $folder) {
                    ForEach(store.folders, id: \.self) { f in
                        Text(folderLabel(f)).tag(f)
                    }
                    Divider()
                    Text("Choose Folder…").tag(chooseFolderTag)
                }
                .labelsHidden()
                .help(folder)
                .frame(width: 190)

                Picker("", selection: $sessionId) {
                    ForEach(folderSessions) { s in
                        Text("\(s.title) · \(s.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))").tag(s.id)
                    }
                    Divider()
                    Text("New session").tag("")
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .pickerStyle(.menu)
            .tint(.primary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if prompt.isEmpty {
                    Text("Prompt")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))

            HStack(spacing: 8) {
                Button { showCalendar.toggle() } label: {
                    Label(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                          systemImage: "calendar")
                        .frame(minWidth: 110, alignment: .leading)
                }
                .popover(isPresented: $showCalendar, arrowEdge: .bottom) {
                    DatePicker("", selection: $day, in: Calendar.current.startOfDay(for: Date())...,
                               displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(10)
                        .onChange(of: day) { _, _ in showCalendar = false }
                }

                TextField("HH:mm", text: $time)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(fireDate == nil ? Color.red.opacity(0.7) : .clear))
                    .help("Time, 24-hour, e.g. 20:30")
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Button(action: add) {
                    Text("Add").frame(width: 56)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(folder.isEmpty || fireDate == nil
                          || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var taskList: some View {
        Group {
            if store.tasks.isEmpty {
                Text("No scheduled prompts")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.tasks) { task in
                            TaskRow(task: task, status: store.statuses[task.id])
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func pickDefaults() {
        if folder.isEmpty || !store.folders.contains(folder) {
            folder = store.folders.first ?? ""
        }
        if !sessionId.isEmpty, !folderSessions.contains(where: { $0.id == sessionId }) {
            sessionId = folderSessions.first?.id ?? ""
        } else if sessionId.isEmpty {
            sessionId = folderSessions.first?.id ?? ""
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addCustomFolder(url.path)
        folder = url.path
    }

    private func add() {
        guard let fireDate else { return }
        do {
            let session = folderSessions.first { $0.id == sessionId }
            try store.add(folder: folder, session: session, prompt: prompt, at: fireDate)
            prompt = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Remaining subscription limits (5-hour session and weekly), from Claude Code's status line data.
struct LimitsBadge: View {
    @EnvironmentObject var store: Store

    var body: some View {
        switch store.limitsTracking {
        case .disabled:
            Button("Show limits") { store.enableLimitsTracking() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Adds a status line to ~/.claude/settings.json that reports your usage limits")
        case .otherStatusLine:
            Text("Limits: n/a")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help("~/.claude/settings.json already has a statusLine. Remove it to let the app show limits.")
        case .enabled:
            if let limits = store.limits, limits.fiveHour != nil || limits.sevenDay != nil {
                HStack(spacing: 10) {
                    if let w = limits.fiveHour { gauge("5h", w) }
                    if let w = limits.sevenDay { gauge("Week", w) }
                }
                .help(details(limits))
            } else {
                Text("Limits: waiting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Appears after the next Claude Code reply in a terminal session"
                          + (store.limitsAccountEmail.map { " (account \($0))" } ?? ""))
            }
        }
    }

    /// Shows % *used*, like Claude Code's own status line and /usage.
    private func gauge(_ label: String, _ w: LimitWindow) -> some View {
        let reset = w.resetsAt < Date()   // window rolled over since the last report
        let used = reset ? 0 : min(100, max(0, w.usedPercent))
        let color: Color = used >= 90 ? .red : used >= 70 ? .orange : .green
        return HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            if used >= 100 {
                Text("limit · \(w.resetsAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.red)
            } else {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 34, height: 4)
                    Capsule().fill(color).frame(width: 34 * used / 100, height: 4)
                }
                Text("\(Int(used.rounded()))% used").monospacedDigit()
            }
        }
        .font(.system(size: 11))
    }

    private func details(_ l: UsageLimits) -> String {
        func line(_ name: String, _ w: LimitWindow?) -> String? {
            guard let w else { return nil }
            if w.resetsAt < Date() { return "\(name): reset at \(w.resetsAt.formatted(date: .omitted, time: .shortened))" }
            let used = Int(min(100, max(0, w.usedPercent)).rounded())
            return "\(name): \(used)% used, resets \(w.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        let account = store.limitsAccountEmail.map { "Terminal account: \($0)" }
        let lines = [account, line("5-hour session", l.fiveHour), line("Weekly", l.sevenDay)].compactMap { $0 }
        return (lines + ["Updated \(l.updated.formatted(.relative(presentation: .named)))"]).joined(separator: "\n")
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: Store
    let task: ScheduledTask
    let status: TaskStatus?
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    private var state: String { status?.state ?? "scheduled" }

    private var color: Color {
        switch state {
        case "sent", "working", "done": return .green
        case "running": return accent
        case "limit": return .orange
        case "failed": return .red
        case "cancelled": return .secondary.opacity(0.5)
        default: return .secondary
        }
    }

    private var stateText: String {
        switch state {
        case "scheduled": return "Scheduled"
        case "running": return "Running"
        case "sent": return "Sent"
        case "working": return "Working"
        case "done": return "Done"
        case "limit": return "Usage limit"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        default: return state
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.prompt.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .strikethrough(state == "cancelled")
                Text("\((task.folder as NSString).lastPathComponent) · \(task.sessionTitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if ["done", "limit", "failed", "working"].contains(state), let message = status?.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(task.fireDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    .font(.system(size: 11, design: .monospaced))
                Text(stateText)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
            }
            Button { store.remove(task) } label: {
                Image(systemName: state == "scheduled" ? "xmark" : "trash")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help(state == "scheduled" ? "Cancel" : "Remove from list")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { openWindow(id: "logs", value: task.id) }
        .help(status?.message.isEmpty == false ? status!.message : "Click to open logs")
        .contextMenu {
            Button("Open Logs") { openWindow(id: "logs", value: task.id) }
            Button("Copy prompt") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.prompt, forType: .string)
            }
        }
    }
}
