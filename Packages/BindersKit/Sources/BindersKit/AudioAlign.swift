import Accelerate
import Foundation

/// Lines up an outside recording of a meeting (a phone, a conference speaker) with the tracks Binders recorded,
/// by cross-correlating speech-activity envelopes so gain, microphone and codec differences don't matter.
public enum AudioAlign {
    public struct Match: Equatable, Sendable {
        /// Seconds into the candidate where the reference starts; negative when the candidate started later.
        public var offset: TimeInterval
        /// Height of the correlation peak in standard deviations of the whole correlation; real matches score well above `strongMatch`.
        public var confidence: Double

        public init(offset: TimeInterval, confidence: Double) {
            self.offset = offset
            self.confidence = confidence
        }
    }

    /// Envelope frames per second (10 ms resolution).
    public static let rate = 100
    /// Confidence above which the offset can be trusted without asking the user.
    public static let strongMatch = 7.0

    /// Level in dB of each 10 ms frame. Pass windows whose length is a multiple of `sampleRate / rate` when streaming a long file.
    public static func levels(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        let hop = sampleRate / rate
        let frames = samples.count / hop
        var levels = [Float](repeating: -60, count: frames)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frames {
                var sum: Float = 0
                let base = frame * hop
                for offset in 0..<hop {
                    let sample = buffer[base + offset]
                    sum += sample * sample
                }
                levels[frame] = max(20 * log10(max((sum / Float(hop)).squareRoot(), 1e-7)), -60)
            }
        }
        return levels
    }

    /// Where the candidate sits relative to the reference, from the dB levels of each (see `levels`).
    ///
    /// A long reference is also matched in 10-minute windows: quiet stretches and slow clock drift blur the peak of a
    /// whole-call correlation, while a window with speech in it matches sharply. When enough windows agree, their median
    /// offset wins and the confidence is the strongest window's.
    public static func align(referenceLevels: [Float], candidateLevels: [Float]) -> Match? {
        let whole = correlate(referenceLevels: referenceLevels, candidateLevels: candidateLevels)
        let window = rate * 600
        guard referenceLevels.count >= window * 2 else { return whole }
        var matches: [Match] = []
        var start = 0
        while start + window <= referenceLevels.count {
            if let found = correlate(referenceLevels: Array(referenceLevels[start..<(start + window)]), candidateLevels: candidateLevels),
               found.confidence >= strongMatch {
                matches.append(Match(offset: found.offset - Double(start) / Double(rate), confidence: found.confidence))
            }
            start += window
        }
        // Windows that agree with each other (within a second) are the real match; a lone peak in a quiet window isn't.
        let sorted = matches.sorted { $0.offset < $1.offset }
        var best: [Match] = []
        for (index, match) in sorted.enumerated() {
            let group = sorted[index...].prefix { $0.offset - match.offset <= 1 }
            if group.count > best.count { best = Array(group) }
        }
        guard best.count >= 2 else { return whole }
        return Match(offset: best[best.count / 2].offset, confidence: Double(best.map(\.confidence).max()!))
    }

    /// One cross-correlation of the whole reference against the whole candidate.
    static func correlate(referenceLevels: [Float], candidateLevels: [Float]) -> Match? {
        let a = centred(activity(referenceLevels))
        let b = centred(activity(candidateLevels))
        let n = a.count, m = b.count
        guard n >= rate * 5, m >= rate * 5 else { return nil }
        var size = 16
        while size < n + m { size <<= 1 }
        guard let forward = vDSP.DFT(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inverse = vDSP.DFT(count: size, direction: .inverse, transformType: .complexComplex, ofType: Float.self) else { return nil }
        let zeros = [Float](repeating: 0, count: size)
        let (aRe, aIm) = forward.transform(inputReal: a + zeros[..<(size - n)], inputImaginary: zeros)
        let (bRe, bIm) = forward.transform(inputReal: b + zeros[..<(size - m)], inputImaginary: zeros)
        // Cross-correlation r[k] = Σ a[i]·b[i+k] is the inverse transform of conj(A)·B.
        let cRe = vDSP.add(vDSP.multiply(aRe, bRe), vDSP.multiply(aIm, bIm))
        let cIm = vDSP.subtract(vDSP.multiply(aRe, bIm), vDSP.multiply(aIm, bRe))
        let (correlation, _) = inverse.transform(inputReal: cRe, inputImaginary: cIm)

        // Valid lags: 0..<m at the front, then -(n-1)...-1 wrapped to the back of the buffer.
        let values = Array(correlation[0..<m]) + Array(correlation[(size - n + 1)...])
        let mean = vDSP.mean(values)
        let deviation = (max(vDSP.meanSquare(values) - mean * mean, 0)).squareRoot()
        guard deviation > 0, let peakIndex = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        let lag = peakIndex < m ? peakIndex : peakIndex - m - (n - 1)
        return Match(offset: Double(lag) / Double(rate), confidence: Double((values[peakIndex] - mean) / deviation))
    }

    /// 0...1 activity above the recording's own noise floor (20th percentile + 6 dB).
    static func activity(_ levels: [Float]) -> [Float] {
        guard !levels.isEmpty else { return [] }
        let floor = levels.sorted()[levels.count / 5] + 6
        return levels.map { min(max(($0 - floor) / 30, 0), 1) }
    }

    private static func centred(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        return vDSP.add(-vDSP.mean(values), values)
    }
}
