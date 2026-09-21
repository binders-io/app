import XCTest
@testable import BindersKit

final class AudioAlignTests: XCTestCase {
    /// Deterministic noise so the tests never flake.
    private struct Generator {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * 2 - 1
        }
    }

    /// Speech-like audio: bursts of noise with pauses, `seconds` long.
    private func speech(seconds: Double, seed: UInt64) -> [Float] {
        var generator = Generator(state: seed)
        var samples: [Float] = []
        samples.reserveCapacity(Int(seconds * 16_000))
        while Double(samples.count) < seconds * 16_000 {
            let burst = Int((0.3 + Double(generator.next() + 1) * 0.8) * 16_000)
            let pause = Int((0.2 + Double(generator.next() + 1) * 0.6) * 16_000)
            for _ in 0..<burst { samples.append(generator.next() * 0.3) }
            for _ in 0..<pause { samples.append(generator.next() * 0.002) }
        }
        return Array(samples.prefix(Int(seconds * 16_000)))
    }

    private func slice(_ samples: [Float], from: Double, to: Double? = nil) -> [Float] {
        Array(samples[Int(from * 16_000)..<(to.map { Int($0 * 16_000) } ?? samples.count)])
    }

    func testFindsWhereAQuieterNoisierCopyStarts() {
        let original = speech(seconds: 200, seed: 7)
        var noise = Generator(state: 99)
        let reference = slice(original, from: 30, to: 100).map { $0 * 0.4 + noise.next() * 0.01 }
        let match = AudioAlign.align(referenceLevels: AudioAlign.levels(reference), candidateLevels: AudioAlign.levels(original))!
        XCTAssertEqual(match.offset, 30, accuracy: 0.03)
        XCTAssertGreaterThan(match.confidence, AudioAlign.strongMatch)
    }

    func testNegativeOffsetWhenTheCandidateStartedLater() {
        let original = speech(seconds: 150, seed: 3)
        let reference = slice(original, from: 0, to: 90)
        let candidate = slice(original, from: 20)
        let match = AudioAlign.align(referenceLevels: AudioAlign.levels(reference), candidateLevels: AudioAlign.levels(candidate))!
        XCTAssertEqual(match.offset, -20, accuracy: 0.03)
        XCTAssertGreaterThan(match.confidence, AudioAlign.strongMatch)
    }

    func testUnrelatedRecordingsDoNotMatchConfidently() {
        let reference = speech(seconds: 60, seed: 11)
        let candidate = speech(seconds: 200, seed: 12)
        if let match = AudioAlign.align(referenceLevels: AudioAlign.levels(reference), candidateLevels: AudioAlign.levels(candidate)) {
            XCTAssertLessThan(match.confidence, AudioAlign.strongMatch)
        }
        XCTAssertNil(AudioAlign.align(referenceLevels: AudioAlign.levels(slice(reference, from: 0, to: 2)),
                                      candidateLevels: AudioAlign.levels(candidate)))
    }

    func testLongReferenceWithDriftAndQuietStretchesStillAligns() {
        // 40 minutes of far-end audio, of which minutes 12 to 28 are near silence, recorded on a device whose clock runs
        // 0.01% fast (100 ppm, generous for real clocks); the reference is the whole call, the candidate started 91 s later.
        var generator = Generator(state: 21)
        let far = speech(seconds: 2_400, seed: 5).enumerated().map { index, sample in
            (index >= 12 * 60 * 16_000 && index < 28 * 60 * 16_000) ? generator.next() * 0.002 : sample
        }
        let candidateSamples = slice(far, from: 91)
        var drifted: [Float] = []
        drifted.reserveCapacity(candidateSamples.count)
        var position = 0.0
        while Int(position) < candidateSamples.count - 1 {
            drifted.append(candidateSamples[Int(position)])
            position += 1.0001
        }
        let match = AudioAlign.align(referenceLevels: AudioAlign.levels(far), candidateLevels: AudioAlign.levels(drifted))!
        XCTAssertEqual(match.offset, -91, accuracy: 1.5)
        XCTAssertGreaterThan(match.confidence, AudioAlign.strongMatch)
    }

    func testLevelsAreTenMillisecondFramesInDecibels() {
        let quiet = [Float](repeating: 0, count: 16_000)
        let loud = [Float](repeating: 0.5, count: 16_000)
        let levels = AudioAlign.levels(quiet + loud)
        XCTAssertEqual(levels.count, 200)
        XCTAssertEqual(levels[0], -60)
        XCTAssertEqual(levels[150], -6.02, accuracy: 0.05)
    }
}
