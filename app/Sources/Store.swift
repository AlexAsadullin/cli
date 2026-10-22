import AppKit

struct SessionInfo: Identifiable, Hashable {
    let id: String          // session UUID
    let folder: String
    let title: String
    let modified: Date
}

struct ScheduledTask: Identifiable, Codable, Hashable {
    let id: String
    let folder: String
    let sessionId: String   // empty = start a new session
    let sessionTitle: String
    let prompt: String
    let fireDate: Date
    var cancelled = false
}

struct LimitWindow: Equatable {
    let usedPercent: Double
    let resetsAt: Date
}

/// Subscription usage limits as last reported by Claude Code to the status line.
struct UsageLimits: Equatable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let updated: Date
}

enum LimitsTracking { case enabled, disabled, otherStatusLine }

struct TaskStatus {
    var state: String       // scheduled, running, sent, working, limit, failed, cancelled
    var message: String
}

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var tasks: [ScheduledTask] = []
    @Published var statuses: [String: TaskStatus] = [:]
    @Published var limits: UsageLimits?
    @Published var limitsTracking: LimitsTracking = .disabled
    @Published var limitsAccountEmail: String?

    let supportDir: URL
    private var timer: Timer?

    /// Folders picked with "Choose Folder…", most recent first.
    @Published var customFolders: [String] = UserDefaults.standard.stringArray(forKey: "customFolders") ?? []

    var folders: [String] {
        var seen = Set<String>()
        return (customFolders + sessions.map(\.folder)).filter { seen.insert($0).inserted }
    }

    func addCustomFolder(_ path: String) {
        customFolders.removeAll { $0 == path }
        customFolders.insert(path, at: 0)
        UserDefaults.standard.set(customFolders, forKey: "customFolders")
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("ClaudeScheduler")
        try? FileManager.default.createDirectory(at: supportDir.appendingPathComponent("tasks"),
                                                 withIntermediateDirectories: true)
        installRunner()
        loadTasks()
        refreshStatuses()
        reloadSessions()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
    }

    // MARK: Sessions

    func reloadSessions() {
        Task.detached(priority: .userInitiated) {
            let found = Self.scanSessions()
            await MainActor.run { self.sessions = found }
        }
    }

    nonisolated static func scanSessions() -> [SessionInfo] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        var result: [SessionInfo] = []

        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                // Sessions deleted in the desktop app leave this marker behind.
                if fm.fileExists(atPath: project.appendingPathComponent("\(id).desktop-released.json").path) { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < cutoff { continue }
                guard let info = parseSession(file, id: id, modified: modified),
                      !info.folder.hasPrefix("/private/"), !info.folder.hasPrefix("/tmp/") else { continue }
                result.append(info)
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    nonisolated static func parseSession(_ url: URL, id: String, modified: Date) -> SessionInfo? {
        // Folder and first prompt are near the start, the latest title near the end:
        // reading both ends keeps the scan fast on multi-MB transcripts.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 256 * 1024
        var data = (try? handle.read(upToCount: chunk)) ?? Data()
        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(chunk) {
            try? handle.seek(toOffset: max(UInt64(chunk), size - UInt64(chunk)))
            data.append(contentsOf: Array("\n".utf8))
            data.append((try? handle.readToEnd()) ?? Data())
        }
        let text = String(decoding: data, as: UTF8.self)
        var cwd: String?
        var customTitle: String?
        var aiTitle: String?
        var firstPrompt: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let wantsCwd = cwd == nil && line.contains("\"cwd\"")
            let wantsTitle = line.contains("\"customTitle\"") || line.contains("\"aiTitle\"")
            let wantsPrompt = firstPrompt == nil && line.contains("\"type\":\"user\"")
            guard wantsCwd || wantsTitle || wantsPrompt,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil { cwd = obj["cwd"] as? String }
            if let t = obj["customTitle"] as? String { customTitle = t }
            if let t = obj["aiTitle"] as? String { aiTitle = t }
            if firstPrompt == nil, obj["type"] as? String == "user",
               let msg = obj["message"] as? [String: Any], let content = msg["content"] as? String,
               !content.hasPrefix("<"), !content.isEmpty {
                firstPrompt = content
            }
        }
        guard let folder = cwd else { return nil }
        let raw = customTitle ?? aiTitle ?? firstPrompt ?? "Untitled session"
        let title = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return SessionInfo(id: id, folder: folder, title: String(title.prefix(70)), modified: modified)
    }

    // MARK: Tasks

    private var tasksFile: URL { supportDir.appendingPathComponent("tasks.json") }
    private var runnerURL: URL { supportDir.appendingPathComponent("run-task.sh") }
    private func taskDir(_ id: String) -> URL { supportDir.appendingPathComponent("tasks/\(id)") }
    private func label(_ id: String) -> String { "com.claudescheduler.task.\(id)" }
    private func plistURL(_ id: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label(id)).plist")
    }

    private func installRunner() {
        for name in ["run-task", "statusline"] {
            guard let bundled = Bundle.main.url(forResource: name, withExtension: "sh") else { continue }
            let dest = supportDir.appendingPathComponent("\(name).sh")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: bundled, to: dest)
        }
    }

    // MARK: Usage limits

    private var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    private var statusLineURL: URL { supportDir.appendingPathComponent("statusline.sh") }

    private func readClaudeSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    func refreshLimits() {
        let command = (readClaudeSettings()["statusLine"] as? [String: Any])?["command"] as? String
        limitsTracking = command == nil ? .disabled
            : command!.contains("ClaudeScheduler/statusline.sh") ? .enabled : .otherStatusLine

        // Only the account the terminal `claude` is logged into (~/.claude.json); the desktop app
        // and other logins save their limits under their own account ids.
        let account = Self.terminalAccount()
        if account?.email != limitsAccountEmail { limitsAccountEmail = account?.email }
        guard let uuid = account?.uuid else { if limits != nil { limits = nil }; return }
        let file = supportDir.appendingPathComponent("limits/\(uuid).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { if limits != nil { limits = nil }; return }

        func window(_ key: String) -> LimitWindow? {
            guard let w = obj[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let next = UsageLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"), updated: updated)
        if next != limits { limits = next }
    }

    nonisolated static func terminalAccount() -> (uuid: String, email: String)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["oauthAccount"] as? [String: Any],
              let uuid = acct["accountUuid"] as? String else { return nil }
        return (uuid, acct["emailAddress"] as? String ?? "")
    }

    /// Points Claude Code's statusLine at our script (only when no other status line is set).
    /// Keeps a backup of settings.json next to it.
    func enableLimitsTracking() {
        var settings = readClaudeSettings()
        guard settings["statusLine"] == nil else { refreshLimits(); return }
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            let backup = claudeSettingsURL.appendingPathExtension("bak-claudescheduler")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: claudeSettingsURL, to: backup)
        }
        settings["statusLine"] = ["type": "command", "command": "\"\(statusLineURL.path)\""]
        if let data = try? JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: claudeSettingsURL)
        }
        refreshLimits()
    }

    private func loadTasks() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: tasksFile),
           let list = try? decoder.decode([ScheduledTask].self, from: data), list != tasks {
            tasks = list
        }
    }

    private func saveTasks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(tasks).write(to: tasksFile)
    }

    func refreshStatuses() {
        loadTasks()   // pick up tasks added outside the app
        refreshLimits()
        var next: [String: TaskStatus] = [:]
        for task in tasks {
            if task.cancelled {
                next[task.id] = TaskStatus(state: "cancelled", message: "Cancelled")
                continue
            }
            let file = taskDir(task.id).appendingPathComponent("status")
            if let line = try? String(contentsOf: file, encoding: .utf8) {
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "|", maxSplits: 2).map(String.init)
                next[task.id] = TaskStatus(state: parts.first ?? "?", message: parts.count > 1 ? parts[1] : "")
            } else {
                next[task.id] = TaskStatus(state: "scheduled", message: "")
            }
        }
        if next.count != statuses.count || next.contains(where: { statuses[$0.key]?.message != $0.value.message }) {
            statuses = next
        }
    }

    func taskFolder(for task: ScheduledTask) -> URL { taskDir(task.id) }

    /// Steps the runner logged, or a summary for tasks that ran before run.log existed.
    func runLog(for task: ScheduledTask) -> String {
        let dir = taskDir(task.id)
        if let log = try? String(contentsOf: dir.appendingPathComponent("run.log"), encoding: .utf8) {
            return log
        }
        let status = statuses[task.id]
        return status?.state == "scheduled" || status == nil
            ? "Not run yet. Fires \(task.fireDate.formatted(date: .abbreviated, time: .shortened))."
            : "Last status: [\(status!.state)] \(status!.message)"
    }

    /// The tmux pane the task sends to: recorded by the runner, or found by session id.
    func tmuxTarget(for task: ScheduledTask) -> String? {
        if let t = try? String(contentsOf: taskDir(task.id).appendingPathComponent("target"), encoding: .utf8) {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !task.sessionId.isEmpty,
              let panes = Self.tmux(["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_start_command}"])
        else { return nil }
        return panes.split(separator: "\n").first { $0.contains(task.sessionId) }
            .map { String($0.split(separator: " ")[0]) }
    }

    /// Opens a Terminal window attached to the tmux session, via a .command file
    /// (needs no Automation permission, unlike scripting Terminal).
    func openTerminal(attachedTo target: String) {
        let session = target.split(separator: ":").first.map(String.init) ?? target
        let url = supportDir.appendingPathComponent("attach-\(session).command")
        let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"
        let script = "#!/bin/zsh\nexec \(tmuxPath) attach -t '\(session)'\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// The session's transcript file. For a new session: the first one started in the folder after the task fired.
    func transcriptURL(for task: ScheduledTask) -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        if !task.sessionId.isEmpty {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            return dirs.map { $0.appendingPathComponent("\(task.sessionId).jsonl") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        let encoded = task.folder.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projects.appendingPathComponent(encoded), includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let c = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      c >= task.fireDate.addingTimeInterval(-60) else { return nil }
                return (url, c)
            }
            .min { $0.1 < $1.1 }?.0
    }

    /// Readable conversation from the session transcript: messages, replies and tool calls.
    nonisolated static func conversation(from url: URL, maxEntries: Int = 400) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "Transcript not found." }
        let timeIn = ISO8601DateFormatter()
        timeIn.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timeOut = DateFormatter()
        timeOut.dateFormat = "MMM d HH:mm"
        var out: [String] = []

        for line in text.split(separator: "\n") {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any] else { continue }
            let time = (obj["timestamp"] as? String).flatMap { timeIn.date(from: $0) }.map { timeOut.string(from: $0) } ?? ""
            let isUser = obj["type"] as? String == "user"

            var blocks: [[String: Any]] = []
            if let s = msg["content"] as? String { blocks = [["type": "text", "text": s]] }
            else if let arr = msg["content"] as? [[String: Any]] { blocks = arr }

            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    guard var t = b["text"] as? String else { continue }
                    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty || t.hasPrefix("<local-command") || t.hasPrefix("<command-") { continue }
                    if isUser, t.hasPrefix("<task-notification>") {
                        let summary = t.components(separatedBy: "<summary>").dropFirst().first?
                            .components(separatedBy: "</summary>").first ?? "Background task update"
                        out.append("\(time)  ⚑ \(summary)")
                    } else {
                        let who = isUser ? "▶ YOU" : "◆ CLAUDE"
                        out.append("\n\(time)  \(who)\n" + t.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
                    }
                case "tool_use":
                    let input = b["input"] as? [String: Any] ?? [:]
                    let what = (input["description"] ?? input["file_path"] ?? input["command"] ?? input["pattern"] ?? "") as? String ?? ""
                    let name = b["name"] as? String ?? "tool"
                    out.append("\(time)      → \(name == "Agent" ? "Agent started" : name): \(what.prefix(140))")
                default:
                    continue
                }
            }
        }
        if out.isEmpty { return "No messages yet." }
        return out.suffix(maxEntries).joined(separator: "\n")
    }

    nonisolated static func tmux(_ args: [String]) -> String? {
        guard let path = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    func add(folder: String, session: SessionInfo?, prompt: String, at date: Date) throws {
        let fire = Calendar.current.date(bySetting: .second, value: 0, of: date) ?? date
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12).description
        let task = ScheduledTask(id: id, folder: folder, sessionId: session?.id ?? "",
                                 sessionTitle: session?.title ?? "New session", prompt: prompt, fireDate: fire)
        let dir = taskDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try prompt.write(to: dir.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)

        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let env = """
        TASK_ID=\(q(id))
        FOLDER=\(q(folder))
        SESSION=\(q(task.sessionId))
        FIRE_EPOCH=\(Int(fire.timeIntervalSince1970))
        LABEL=\(q(label(id)))
        """
        try env.write(to: dir.appendingPathComponent("task.env"), atomically: true, encoding: .utf8)

        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: fire)
        let plist: [String: Any] = [
            "Label": label(id),
            "ProgramArguments": ["/bin/zsh", runnerURL.path, dir.path],
            "StartCalendarInterval": ["Month": parts.month!, "Day": parts.day!, "Hour": parts.hour!, "Minute": parts.minute!],
            "AbandonProcessGroup": true,   // keep the tmux server alive after the job exits
            "StandardOutPath": dir.appendingPathComponent("launchd.log").path,
            "StandardErrorPath": dir.appendingPathComponent("launchd.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL(id))
        launchctl(["bootstrap", "gui/\(getuid())", plistURL(id).path])
        // Times in the past (or this minute) run right away.
        if fire.timeIntervalSinceNow < 60 {
            launchctl(["kickstart", "gui/\(getuid())/\(label(id))"])
        }

        tasks.append(task)
        tasks.sort { $0.fireDate < $1.fireDate }
        saveTasks()
        refreshStatuses()
    }

    /// Cancels a pending task, or removes a finished one from the list.
    func remove(_ task: ScheduledTask) {
        launchctl(["bootout", "gui/\(getuid())/\(label(task.id))"])
        try? FileManager.default.removeItem(at: plistURL(task.id))
        let state = statuses[task.id]?.state ?? "scheduled"
        if state == "scheduled", let i = tasks.firstIndex(of: task), !task.cancelled {
            tasks[i].cancelled = true
        } else {
            tasks.removeAll { $0.id == task.id }
            try? FileManager.default.removeItem(at: taskDir(task.id))
        }
        saveTasks()
        refreshStatuses()
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
