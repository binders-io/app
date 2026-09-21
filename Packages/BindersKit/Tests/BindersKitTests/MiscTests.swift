import XCTest
@testable import BindersKit

final class EditLearnerTests: XCTestCase {
    let known: (String) -> Bool = { ["the", "we", "use", "for", "dictation", "and", "run", "it", "in", "whispering", "fluid", "audio"].contains($0) }

    func testEditedRegion() {
        let initial = "Notes: we use whispering for dictation. End"
        let final = "Notes: we use Binders for dictation. End"
        XCTAssertEqual(EditLearner.editedRegion(initialValue: initial, inserted: "we use whispering for dictation.", finalValue: final),
                       "we use Binders for dictation.")
        XCTAssertNil(EditLearner.editedRegion(initialValue: initial, inserted: "we use whispering for dictation.", finalValue: "Changed everything"))
    }

    func testLearnsProperNounFix() {
        let corrections = EditLearner.corrections(inserted: "we use finders for dictation", edited: "we use Binders for dictation", isKnownWord: known)
        XCTAssertEqual(corrections, [LearnedCorrection(heard: "finders", corrected: "Binders")])
    }

    func testLearnsMultiWordToCamelCase() {
        let corrections = EditLearner.corrections(inserted: "run it in fluid audio", edited: "run it in FluidAudio", isKnownWord: known)
        XCTAssertEqual(corrections, [LearnedCorrection(heard: "fluid audio", corrected: "FluidAudio")])
    }

    func testIgnoresRewritesAndCapitalization() {
        XCTAssertEqual(EditLearner.corrections(inserted: "the dictation", edited: "The dictation", isKnownWord: known), [])
        XCTAssertEqual(EditLearner.corrections(inserted: "we use it", edited: "completely different sentence now", isKnownWord: known), [])
    }
}

final class StyleResolverTests: XCTestCase {
    func testBundleAndDomainMapping() {
        XCTAssertEqual(StyleResolver.category(for: AppContext(bundleID: "com.tinyspeck.slackmacgap")), .work)
        XCTAssertEqual(StyleResolver.category(for: AppContext(bundleID: "com.mitchellh.ghostty")), .coding)
        XCTAssertEqual(StyleResolver.category(for: AppContext(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox")), .email)
        XCTAssertEqual(StyleResolver.category(for: AppContext(bundleID: "com.google.Chrome", url: "https://www.nytimes.com")), .other)
        XCTAssertEqual(StyleResolver.category(for: AppContext(bundleID: "com.jetbrains.intellij")), .coding)
    }

    func testOverridesWin() {
        let context = AppContext(bundleID: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(StyleResolver.category(for: context, overrides: ["com.tinyspeck.slackmacgap": .personal]), .personal)
    }
}

final class AudioAndStatsTests: XCTestCase {
    func testNormalizeBoostsQuietSpeech() {
        let quiet = (0..<16000).map { Float(sin(Double($0) * 0.05)) * 0.01 }
        let boosted = AudioMath.normalize(quiet)
        XCTAssertGreaterThan(AudioMath.rms(boosted), AudioMath.rms(quiet) * 5)
        XCTAssertLessThanOrEqual(boosted.map(abs).max() ?? 0, 1)
        XCTAssertTrue(AudioMath.isSilent([Float](repeating: 0.00001, count: 16000)))
        XCTAssertFalse(AudioMath.isSilent(quiet))
    }

    func testStats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let records = [
            UsageRecord(date: now, words: 150, duration: 60),
            UsageRecord(date: now - day, words: 150, duration: 60),
            UsageRecord(date: now - 3 * day, words: 100, duration: 60),
        ]
        let stats = StatsCalculator.compute(records, now: now, calendar: calendar)
        XCTAssertEqual(stats.totalWords, 400)
        XCTAssertEqual(stats.averageWPM, 133)
        XCTAssertEqual(stats.streakDays, 2)
        XCTAssertEqual(stats.minutesSaved, 7)
    }
}
