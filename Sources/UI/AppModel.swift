import SwiftUI
import AppKit

enum Phase: Equatable {
    case idle                         // no scan yet
    case scanning(done: Int, total: Int)
    case ready                        // BPMs known, nothing sorted yet
    case sorting(done: Int, total: Int)
    case finished
}

enum Key {
    static let folder = "folder", ranges = "ranges", mode = "mode", useTags = "useTags"
    static let window = "detectWindow", other = "otherFolder", disclaimer = "disclaimerAcceptedVersion"
}

@MainActor
final class AppModel: ObservableObject {
    @Published var folder: URL? { didSet { folderChanged() } }
    @Published var ranges: [TempoRange] { didSet { saveRanges() } }
    @Published var tracks: [Track] = []
    @Published var phase: Phase = .idle
    @Published var message: String?
    @Published var lastOps: [FileOp] = []
    @Published var lastMode: SortMode = .copy
    /// Folder name each track was put in by the last sort, by its new location.
    @Published var placed: [URL: String] = [:]

    @AppStorage(Key.mode) var modeRaw = SortMode.copy.rawValue
    @AppStorage(Key.useTags) var useTags = true
    @AppStorage(Key.window) var windowSetting = 0          // 0 = automatic
    @AppStorage(Key.other) var useOtherFolder = false

    private var job: Task<Void, Never>?
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal]

    var mode: SortMode { SortMode(rawValue: modeRaw) ?? .copy }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Key.ranges), let r = try? JSONDecoder().decode([TempoRange].self, from: data), r.count >= 2 {
            ranges = r
        } else {
            ranges = TempoRange.defaults
        }
        if let p = d.string(forKey: Key.folder), FileManager.default.fileExists(atPath: p) {
            folder = URL(fileURLWithPath: p, isDirectory: true)
            folderChanged()
        }
    }

    private func saveRanges() {
        if let d = try? JSONEncoder().encode(ranges) { UserDefaults.standard.set(d, forKey: Key.ranges) }
    }

    private func folderChanged() {
        job?.cancel()
        UserDefaults.standard.set(folder?.path, forKey: Key.folder)
        lastOps = []; placed = [:]; message = nil
        tracks = folder.map(Scanner.audioFiles(in:)) ?? []
        // Fill in anything already known, so a folder you've scanned before shows its BPMs at once.
        let w = window
        for i in tracks.indices {
            if let (b, o) = BPMCache.shared.get(tracks[i].url, window: w, useTags: useTags) { tracks[i].bpm = b; tracks[i].origin = o }
        }
        phase = tracks.isEmpty || tracks.contains(where: { $0.bpm == nil }) ? .idle : .ready
    }

    // MARK: Derived

    var window: Int { windowSetting == 0 ? Analyzer.automaticWindow(for: ranges) : windowSetting }
    var rangeProblem: String? { TempoRange.problem(in: ranges) }
    var busy: Bool {
        switch phase { case .scanning, .sorting: return true; default: return false }
    }
    var unscannedCount: Int { tracks.filter { $0.bpm == nil && !$0.failed }.count }

    func color(for name: String) -> Color {
        if let i = ranges.firstIndex(where: { $0.folderName == name }) { return palette[i % palette.count] }
        return .gray
    }

    /// Which folder a track goes into, or nil if it stays where it is.
    func target(for t: Track) -> String? {
        if let p = placed[t.url] { return p }
        guard let bpm = t.bpm else { return nil }
        if let r = ranges.first(where: { $0.contains(bpm) }) { return r.folderName }
        return useOtherFolder ? TempoRange.otherFolderName : nil
    }

    func count(in r: TempoRange) -> Int { tracks.filter { target(for: $0) == r.folderName }.count }
    var plan: [Track] { tracks.filter { placed[$0.url] == nil && target(for: $0) != nil } }
    var outsideCount: Int { tracks.filter { t in t.bpm.map { b in !ranges.contains { $0.contains(b) } } ?? false }.count }
    var noBPMCount: Int { tracks.filter { $0.failed }.count }

    // MARK: Folder

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose the folder with your music. Subfolders are included."
        if let f = folder { p.directoryURL = f }
        if p.runModal() == .OK, let u = p.url { folder = u }
    }

    func revealFolder() { if let f = folder { NSWorkspace.shared.activateFileViewerSelecting([f]) } }

    // MARK: Scan

    func scan(rescanAll: Bool = false) {
        guard folder != nil, !busy else { return }
        if rescanAll { BPMCache.shared.clear() }
        let f = folder; folder = f              // re-list the files (picks up new ones, drops moved ones)
        let todo = tracks.indices.filter { tracks[$0].bpm == nil }
        let urls = todo.map { tracks[$0].url }
        let w = window, tags = useTags
        phase = .scanning(done: 0, total: urls.count)
        message = nil
        guard !urls.isEmpty else { phase = .ready; return }

        job = Task {
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
            var done = 0
            await withTaskGroup(of: (URL, (Double, BPMOrigin)?).self) { group in
                var next = 0
                func add() {
                    guard next < urls.count else { return }
                    let u = urls[next]; next += 1
                    group.addTask { (u, await Analyzer.bpm(for: u, window: w, useTags: tags)) }
                }
                for _ in 0..<width { add() }
                while let (u, result) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let i = tracks.firstIndex(where: { $0.url == u }) {
                        if let (b, o) = result { tracks[i].bpm = b; tracks[i].origin = o } else { tracks[i].failed = true }
                    }
                    done += 1
                    phase = .scanning(done: done, total: urls.count)
                    add()
                }
            }
            BPMCache.shared.save()
            phase = Task.isCancelled ? .idle : .ready
        }
    }

    func stop() { job?.cancel() }

    // MARK: Sort

    /// Bytes a copy would add, and whether the disk has room for it.
    var copyBytes: Int64 { plan.reduce(0) { $0 + $1.size } }
    var freeBytes: Int64? {
        guard let f = folder,
              let v = try? f.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return v.volumeAvailableCapacityForImportantUsage
    }

    func sort() {
        guard let root = folder, !busy, rangeProblem == nil else { return }
        let items = plan.compactMap { t in target(for: t).map { (t, $0) } }
        guard !items.isEmpty else { return }
        let m = mode
        if m == .copy, let free = freeBytes, free < copyBytes + 200_000_000 {
            message = "Not enough free space: copying needs \(bytes(copyBytes)) and the disk has \(bytes(free)). Try Move, or free up space."
            return
        }
        phase = .sorting(done: 0, total: items.count)
        message = nil
        lastMode = m

        job = Task {
            var ops: [FileOp] = [], skipped: [String] = []
            for (n, (t, folderName)) in items.enumerated() {
                if Task.isCancelled { break }
                let dir = root.appendingPathComponent(folderName, isDirectory: true)
                let result: Result<FileOp?, Error> = await Task.detached(priority: .userInitiated) {
                    // Already there from an earlier copy? (same name and size) Then skip it.
                    let existing = dir.appendingPathComponent(t.url.lastPathComponent)
                    if m == .copy, let s = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.size] as? NSNumber)?.int64Value,
                       s == t.size { return .success(nil) }
                    return Result { try FileSorter.perform(m, file: t.url, into: dir) }
                }.value
                switch result {
                case .success(let op?):
                    ops.append(op)
                    if m == .move { BPMCache.shared.moved(from: op.from, to: op.to) }
                    if let i = tracks.firstIndex(where: { $0.url == t.url }) {
                        if m == .move {
                            let moved = Track(url: op.to, size: t.size, bpm: t.bpm, origin: t.origin)
                            tracks[i] = moved
                            placed[op.to] = folderName
                        } else {
                            placed[t.url] = folderName
                        }
                    }
                case .success(nil):
                    skipped.append("\(t.name): already in \(folderName)")
                    placed[t.url] = folderName
                case .failure(let e):
                    skipped.append("\(t.name): \(e.localizedDescription)")
                }
                phase = .sorting(done: n + 1, total: items.count)
            }
            BPMCache.shared.save()
            lastOps = ops
            let verb = m == .copy ? "Copied" : "Moved"
            let folders = Set(ops.map { $0.to.deletingLastPathComponent().lastPathComponent }).count
            var msg = "\(verb) \(ops.count) track\(ops.count == 1 ? "" : "s") into \(folders) folder\(folders == 1 ? "" : "s")."
            if !skipped.isEmpty { msg += " Skipped \(skipped.count): " + skipped.prefix(3).joined(separator: "; ") + (skipped.count > 3 ? "…" : "") }
            if Task.isCancelled { msg = "Stopped. " + msg }
            message = msg
            phase = .finished
            writeLog(ops: ops, skipped: skipped, mode: m)
        }
    }

    func undo() {
        guard !lastOps.isEmpty, !busy else { return }
        let ops = lastOps, m = lastMode
        let failed = FileSorter.undo(ops, mode: m)
        lastOps = []
        BPMCache.shared.save()
        let f = folder; folder = f           // re-list from disk
        message = failed == 0
            ? (m == .move ? "Undone: \(ops.count) tracks are back where they were." : "Undone: \(ops.count) copies moved to the Trash.")
            : "Undone, except \(failed) file\(failed == 1 ? "" : "s") that couldn't be put back (something else is in its place)."
    }

    /// A plain-text record of every file copied or moved, in Application Support (not in your music folder).
    private func writeLog(ops: [FileOp], skipped: [String], mode: SortMode) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo Sort/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"
        var text = "Tempo Sort \(mode.rawValue) — \(Date())\n\n"
        text += ops.map { "\($0.from.path)\n  -> \($0.to.path)" }.joined(separator: "\n")
        if !skipped.isEmpty { text += "\n\nSkipped:\n" + skipped.joined(separator: "\n") }
        try? text.write(to: dir.appendingPathComponent("\(f.string(from: Date())) \(mode.rawValue).txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Ranges

    func addRange() {
        guard ranges.count < TempoRange.maxCount else { return }
        let top = ranges.map(\.high).max() ?? 120
        ranges.append(TempoRange(low: top, high: min(400, top + 20)))
    }

    func removeRange(_ r: TempoRange) {
        guard ranges.count > TempoRange.minCount else { return }
        ranges.removeAll { $0.id == r.id }
    }

    func usePreset(_ p: [(Int, Int)]) { ranges = p.map { TempoRange(low: $0.0, high: $0.1) } }
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
