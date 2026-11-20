import Foundation

// Core logic: no SwiftUI or AppKit here, so it can move to a Windows or Linux version as is.

// MARK: - Ranges

struct TempoRange: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var low: Int
    var high: Int

    /// "80bpm-100bpm"
    var folderName: String { "\(low)bpm-\(high)bpm" }
    var isValid: Bool { low >= 20 && high <= 400 && low < high }
    func contains(_ bpm: Double) -> Bool { bpm >= Double(low) && bpm <= Double(high) }

    static let defaults: [TempoRange] = [
        TempoRange(low: 80, high: 100), TempoRange(low: 100, high: 120), TempoRange(low: 120, high: 140),
    ]
    static let minCount = 2, maxCount = 5

    /// Matches folder names this app makes, so a rescan doesn't pick up tracks it already sorted.
    static func isRangeFolderName(_ name: String) -> Bool {
        name.range(of: #"^\d{2,3}bpm-\d{2,3}bpm$"#, options: .regularExpression) != nil || name == otherFolderName
    }
    static let otherFolderName = "other-bpm"

    /// Problems with a set of ranges, or nil if they're fine. Sharing a border (80–100, 100–120) is fine:
    /// a track at exactly 100 goes to the first range.
    static func problem(in ranges: [TempoRange]) -> String? {
        if ranges.count < minCount { return "Add at least \(minCount) ranges." }
        if let bad = ranges.first(where: { !$0.isValid }) {
            return "\(bad.low)–\(bad.high) isn't a valid range: the first number must be lower, between 20 and 400."
        }
        for i in ranges.indices {
            for j in ranges.indices where j > i {
                let a = ranges[i], b = ranges[j]
                if a.low < b.high && b.low < a.high { return "\(a.low)–\(a.high) and \(b.low)–\(b.high) overlap." }
            }
        }
        if Set(ranges.map(\.folderName)).count != ranges.count { return "Two ranges are the same." }
        return nil
    }
}

// MARK: - Tracks

enum BPMOrigin: String, Codable { case tag, detected }

struct Track: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let size: Int64
    var bpm: Double?
    var origin: BPMOrigin?
    var failed = false          // couldn't be read

    var name: String { url.lastPathComponent }
    var bpmText: String {
        guard let bpm else { return failed ? "No BPM" : "—" }
        return bpm == bpm.rounded() ? "\(Int(bpm))" : String(format: "%.1f", bpm)
    }
}

enum Scanner {
    static let audioExtensions: Set<String> = ["mp3", "wav", "wave", "aif", "aiff", "aifc", "flac", "m4a", "aac", "alac", "caf"]

    /// Every audio file in `folder` and its subfolders, skipping hidden files and folders this app made.
    static func audioFiles(in folder: URL) -> [Track] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .nameKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Track] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                   TempoRange.isRangeFolderName(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true, audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            out.append(Track(url: url, size: Int64(v?.fileSize ?? 0)))
        }
        return out.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}

// MARK: - Remembering BPMs, so a second scan of the same files is instant

final class BPMCache: @unchecked Sendable {
    struct Entry: Codable { var size: Int64; var modified: Double; var bpm: Double; var origin: BPMOrigin; var window: Int }

    static let shared = BPMCache()
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo Sort", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bpm-cache.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e }
    }

    private static func stamp(_ url: URL) -> (Int64, Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let s = (a[.size] as? NSNumber)?.int64Value, let m = a[.modificationDate] as? Date else { return nil }
        return (s, m.timeIntervalSince1970)
    }

    /// A saved value, if the file hasn't changed. Detected values only count if found with the same window.
    func get(_ url: URL, window: Int, useTags: Bool) -> (Double, BPMOrigin)? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[url.path], let (s, m) = Self.stamp(url), e.size == s, e.modified == m else { return nil }
        if e.origin == .tag { return useTags ? (e.bpm, .tag) : nil }
        return e.window == window ? (e.bpm, .detected) : nil
    }

    func set(_ url: URL, bpm: Double, origin: BPMOrigin, window: Int) {
        guard let (s, m) = Self.stamp(url) else { return }
        lock.lock(); entries[url.path] = Entry(size: s, modified: m, bpm: bpm, origin: origin, window: window); lock.unlock()
    }

    /// After a move, the same file lives at a new path.
    func moved(from: URL, to: URL) {
        lock.lock(); if let e = entries.removeValue(forKey: from.path) { entries[to.path] = e }; lock.unlock()
    }

    func save() {
        lock.lock(); let snapshot = entries; lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
    }

    func clear() { lock.lock(); entries = [:]; lock.unlock(); try? FileManager.default.removeItem(at: url) }
}

enum Analyzer {
    /// Tag first (if allowed), then detection within `window` ..< 2×`window` BPM.
    static func bpm(for url: URL, window: Int, useTags: Bool) async -> (Double, BPMOrigin)? {
        if let c = BPMCache.shared.get(url, window: window, useTags: useTags) { return c }
        if useTags, let t = await BPMTag.read(url) {
            BPMCache.shared.set(url, bpm: t, origin: .tag, window: window)
            return (t, .tag)
        }
        guard let d = BPMDetector.detect(url, low: Double(window)) else { return nil }
        BPMCache.shared.set(url, bpm: d, origin: .detected, window: window)
        return (d, .detected)
    }

    /// The detection window to use for a set of ranges: the octave that starts at the lowest range,
    /// kept between 60 and 100 so typical tempos land in it.
    static func automaticWindow(for ranges: [TempoRange]) -> Int {
        min(100, max(60, ranges.map(\.low).min() ?? 85))
    }
}

// MARK: - Copying or moving

enum SortMode: String, CaseIterable, Identifiable {
    case copy, move
    var id: String { rawValue }
}

struct FileOp: Codable { let from: URL; let to: URL }

struct SortReport {
    var done: [FileOp] = []
    var skipped: [(URL, String)] = []
}

enum FileSorter {
    /// A free name in `dir`: "Track.mp3", then "Track (2).mp3", …
    static func freeDestination(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }

    /// Copies or moves one file into `dir`. Never overwrites: a name that's taken gets " (2)".
    static func perform(_ mode: SortMode, file: URL, into dir: URL) throws -> FileOp {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = freeDestination(for: file.lastPathComponent, in: dir)
        switch mode {
        case .copy: try fm.copyItem(at: file, to: dest)
        case .move: try fm.moveItem(at: file, to: dest)
        }
        return FileOp(from: file, to: dest)
    }

    /// Undo: moves go back where they came from; copies go to the Trash. Returns how many couldn't be undone.
    static func undo(_ ops: [FileOp], mode: SortMode) -> Int {
        let fm = FileManager.default
        var failed = 0
        for op in ops.reversed() {
            do {
                switch mode {
                case .move:
                    try fm.createDirectory(at: op.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard !fm.fileExists(atPath: op.from.path) else { failed += 1; continue }
                    try fm.moveItem(at: op.to, to: op.from)
                    BPMCache.shared.moved(from: op.to, to: op.from)
                case .copy:
                    try fm.trashItem(at: op.to, resultingItemURL: nil)
                }
            } catch { failed += 1 }
        }
        // Remove range folders that are now empty.
        for dir in Set(ops.map { $0.to.deletingLastPathComponent() }) {
            if let items = try? fm.contentsOfDirectory(atPath: dir.path), items.filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.trashItem(at: dir, resultingItemURL: nil)
            }
        }
        return failed
    }
}
