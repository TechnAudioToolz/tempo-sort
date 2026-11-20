import AVFoundation
import Accelerate

// BPM from the file's tag, or detected from the audio.
// Taken from Crate Sort for VLC (same detector, tuned on tagged dance tracks).
// This is the only file tied to Apple's audio frameworks: a Windows or Linux port swaps the
// decoding here (AVAudioFile) and keeps everything else in Core.

// MARK: - Reading the BPM tag (ID3 TBPM, iTunes tmpo, FLAC/Ogg BPM comments)

enum BPMTag {
    static func read(_ url: URL) async -> Double? {
        if url.pathExtension.lowercased() == "flac", let v = flacBPM(url) { return v }
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for f in formats {
            guard let items = try? await asset.loadMetadata(for: f) else { continue }
            for item in items {
                let id = item.identifier?.rawValue.lowercased() ?? ""
                let key = (item.key as? String)?.lowercased() ?? ""
                let isBPM = item.identifier == .id3MetadataBeatsPerMinute
                    || item.identifier == .iTunesMetadataBeatsPerMin
                    || key == "tbpm" || key == "tbp" || key == "bpm" || key == "tmpo" || id.hasSuffix("/bpm") || id.hasSuffix("/tbpm")
                guard isBPM else { continue }
                if let n = try? await item.load(.numberValue)?.doubleValue, n > 20, n < 400 { return n }
                if let s = try? await item.load(.stringValue), let n = number(s) { return n }
            }
        }
        return nil
    }

    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let n = Double(t.prefix { "0123456789.".contains($0) }), n > 20, n < 400 else { return nil }
        return n
    }

    /// Reads the VORBIS_COMMENT block of a FLAC file and looks for BPM= / TBPM= / TEMPO=.
    static func flacBPM(_ url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let magic = try? h.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        while true {
            guard let hdr = try? h.read(upToCount: 4), hdr.count == 4 else { return nil }
            let last = hdr[0] & 0x80 != 0, type = hdr[0] & 0x7F
            let len = Int(hdr[1]) << 16 | Int(hdr[2]) << 8 | Int(hdr[3])
            if type == 4 {
                guard let b = try? h.read(upToCount: len), b.count == len else { return nil }
                func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 | Int(b[i+2]) << 16 | Int(b[i+3]) << 24 }
                var i = 0
                guard b.count >= 4 else { return nil }
                i += 4 + u32(0)                               // vendor string
                guard i + 4 <= b.count else { return nil }
                let n = u32(i); i += 4
                for _ in 0..<n {
                    guard i + 4 <= b.count else { return nil }
                    let l = u32(i); i += 4
                    guard i + l <= b.count else { return nil }
                    let c = String(decoding: b[i..<i+l], as: UTF8.self); i += l
                    let parts = c.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2, ["bpm", "tbpm", "tempo"].contains(parts[0].lowercased()), let v = number(parts[1]) { return v }
                }
                return nil
            }
            guard (try? h.seek(toOffset: h.offsetInFile + UInt64(len))) != nil, !last else { return nil }
        }
    }
}

// MARK: - Detecting the BPM from the audio

enum BPMDetector {
    /// Decodes up to 40 s from the middle of the track, builds an onset (kick) envelope,
    /// and finds the beat period with a comb of autocorrelations.
    /// Finds the tempo within one octave, `low` ..< 2×`low` (a beat detector can't tell 85 from 170 on its own).
    nonisolated static func detect(_ url: URL, low: Double) -> Double? {
        let range = (low: low, high: low * 2)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        let total = file.length
        guard sr > 0, total > Int64(sr * 8) else { return nil }
        let want = min(total, AVAudioFramePosition(sr * 40))
        file.framePosition = max(0, (total - want) / 2)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(want)),
              (try? file.read(into: buf, frameCount: AVAudioFrameCount(want))) != nil,
              let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
        guard n > Int(sr * 6) else { return nil }

        // Mono mix.
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chans { vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(n)) }

        // Two bands: low (kick, < ~150 Hz) and full, via a simple one-pole low-pass.
        let a = Float(exp(-2 * Double.pi * 150 / sr))
        var low = [Float](repeating: 0, count: n)
        var y: Float = 0
        for i in 0..<n { y = (1 - a) * mono[i] + a * y; low[i] = y }

        // Energy envelope at ~400 frames per second.
        let hop = max(1, Int(sr / 400)), fps = sr / Double(hop)
        let frames = n / hop
        func envelope(_ x: [Float]) -> [Float] {
            var e = [Float](repeating: 0, count: frames)
            x.withUnsafeBufferPointer { p in
                for f in 0..<frames {
                    var s: Float = 0
                    vDSP_svesq(p.baseAddress! + f * hop, 1, &s, vDSP_Length(hop))
                    e[f] = log1p(1000 * s / Float(hop))
                }
            }
            // Onset strength: rise in energy only.
            var o = [Float](repeating: 0, count: frames)
            for f in 1..<frames { o[f] = max(0, e[f] - e[f - 1]) }
            var mean: Float = 0
            vDSP_meanv(o, 1, &mean, vDSP_Length(frames))
            var neg = -mean
            vDSP_vsadd(o, 1, &neg, &o, 1, vDSP_Length(frames))
            return o
        }
        let oLow = envelope(low), oAll = envelope(mono)
        var onset = [Float](repeating: 0, count: frames)
        var two: Float = 2
        vDSP_vsma(oLow, 1, &two, oAll, 1, &onset, 1, vDSP_Length(frames))   // kick-weighted

        // Autocorrelation at a lag (fractional lags interpolated).
        func acf(_ lag: Int) -> Float {
            guard lag > 0, lag < frames else { return 0 }
            var r: Float = 0
            vDSP_dotpr(onset, 1, Array(onset[lag...]), 1, &r, vDSP_Length(frames - lag))
            return r / Float(frames - lag)
        }
        func acfF(_ lag: Double) -> Float {
            let l = Int(lag), f = Float(lag - Double(l))
            return acf(l) * (1 - f) + acf(l + 1) * f
        }

        let combN = 8, sigma = 0.9
        // Score each tempo with a comb of 1x..8x the beat period (long combs pin the tempo down),
        // gently favouring club tempos around 128 so a 3-beat or half-time pattern doesn't win.
        func score(_ bpm: Double) -> Float {
            let period = fps * 60 / bpm
            var s: Float = 0
            for k in 1...combN where period * Double(k) < Double(frames) * 0.6 {
                s += acfF(period * Double(k)) / Float(k).squareRoot()
            }
            let x = log2(bpm / 128) / sigma
            return s * Float(exp(-0.5 * x * x))
        }
        var best = 0.0, bestScore: Float = -.infinity
        var bpm = range.low
        while bpm < range.high {
            let s = score(bpm)
            if s > bestScore { bestScore = s; best = bpm }
            bpm += 0.05
        }
        guard best > 0, bestScore > 0 else { return nil }
        // A 3-beat pattern can beat the real 4/4 pulse: if 1.5x (or 4/3x) the tempo scores almost
        // as well and is closer to club tempo, it's the real one. Search near it for the exact peak.
        let keep: Float = 0.7     // tuned on tagged tracks
        for ratio in [1.5, 4.0 / 3.0] {
            let c = best * ratio
            guard c < range.high, abs(log2(c / 128)) < abs(log2(best / 128)) else { continue }
            var cb = c, cs: Float = -.infinity
            var b = c - 1.5
            while b <= c + 1.5 { let s = score(b); if s > cs { cs = s; cb = b }; b += 0.05 }
            if cs >= bestScore * keep { best = cb; bestScore = cs; break }
        }
        // Most dance music sits on whole numbers.
        let whole = best.rounded()
        return abs(best - whole) <= 0.35 ? whole : (best * 10).rounded() / 10
    }
}

