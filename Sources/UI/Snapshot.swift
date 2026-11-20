import SwiftUI
import AppKit

// Test hooks, used only when launched with these arguments:
//   --ranges 80-100,100-120   use these ranges
//   --folder <path>     open this folder
//   --scan              find BPMs and wait for them
//   --sort              then copy or move (no confirmation)
//   --undo              then undo it
//   --snapshot <png>    save a picture of the window, then quit
enum Snapshot {
    @MainActor
    static func runIfAsked(_ model: AppModel) async {
        let a = CommandLine.arguments
        func value(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        guard a.contains(where: { $0.hasPrefix("--") }) else { return }
        if let r = value("--ranges") {           // "80-100,100-120"
            let parsed = r.split(separator: ",").compactMap { part -> TempoRange? in
                let n = part.split(separator: "-").compactMap { Int($0) }
                return n.count == 2 ? TempoRange(low: n[0], high: n[1]) : nil
            }
            if parsed.count >= 2 { model.ranges = parsed }
        }
        if let f = value("--folder") { model.folder = URL(fileURLWithPath: f, isDirectory: true) }
        if a.contains("--scan") {
            model.scan()
            while model.busy { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        if a.contains("--sort") {
            model.sort()
            while model.busy { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        if a.contains("--undo") { model.undo() }
        if let path = value("--snapshot") {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let view = win.contentView?.superview ?? win.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            BPMCache.shared.save()
            exit(0)          // terminate() is refused while a sheet is open
        }
    }
}
