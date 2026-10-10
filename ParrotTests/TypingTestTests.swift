import AppKit
import XCTest

@testable import Parrot

/// Typing test scoring and the stats math behind time saved, percent faster
/// and the share card. The sheet and the PNG save panel need a GUI session
/// and are not covered here; rendering the card to PNG is.
@MainActor
final class TypingTestTests: XCTestCase {

    // MARK: - Typing Test

    func testPerfectTypingScoresCharactersOverFivePerMinute() {
        let prompt = "the quick brown parrot"
        // 22 characters in 6 seconds: 22 / 5 / 0.1 = 44 WPM.
        let score = TypingTest.score(prompt: prompt, typed: prompt, elapsed: 6)
        XCTAssertEqual(score.correctCharacters, 22)
        XCTAssertEqual(score.typedCharacters, 22)
        XCTAssertEqual(score.wordsCorrect, 4)
        XCTAssertEqual(score.wpm, 44, accuracy: 0.001)
    }

    func testMistakesCountOnlyMatchingCharactersAndWords() {
        let score = TypingTest.score(prompt: "hello world again", typed: "hellp world", elapsed: 60)
        // "hellp world" matches 10 of 11 positions.
        XCTAssertEqual(score.correctCharacters, 10)
        XCTAssertEqual(score.typedCharacters, 11)
        XCTAssertEqual(score.wordsCorrect, 1)
        XCTAssertEqual(score.wpm, 2, accuracy: 0.001)
    }

    func testNoTimeOrNoTypingIsZero() {
        XCTAssertEqual(TypingTest.score(prompt: "abc", typed: "abc", elapsed: 0).wpm, 0)
        XCTAssertEqual(TypingTest.score(prompt: "abc", typed: "", elapsed: 10).wpm, 0)
    }

    func testSavedSpeedNeedsEnoughTypingAndIsRoundedAndCapped() {
        XCTAssertNil(TypingTest.savedWPM(for: TypingScore(wpm: 80, correctCharacters: 9, typedCharacters: 9, wordsCorrect: 2)))
        XCTAssertNil(TypingTest.savedWPM(for: TypingScore(wpm: 3, correctCharacters: 50, typedCharacters: 50, wordsCorrect: 9)))
        XCTAssertEqual(TypingTest.savedWPM(for: TypingScore(wpm: 61.6, correctCharacters: 120, typedCharacters: 125, wordsCorrect: 22)), 62)
        XCTAssertEqual(TypingTest.savedWPM(for: TypingScore(wpm: 900, correctCharacters: 120, typedCharacters: 120, wordsCorrect: 22)), 250)
    }

    func testPromptsCycle() {
        XCTAssertGreaterThanOrEqual(TypingTest.prompts.count, 8)
        XCTAssertEqual(TypingTest.nextPromptIndex(after: 0), 1)
        XCTAssertEqual(TypingTest.nextPromptIndex(after: TypingTest.prompts.count - 1), 0)
        XCTAssertTrue(TypingTest.prompts.allSatisfy { $0.count > 80 })
    }

    func testDefaultTypingSpeedIsForty() {
        let suite = "TypingTestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(settings.general.typingWPM, 40)
        settings.general.typingWPM = 65
        XCTAssertEqual(AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore()).general.typingWPM, 65)
    }

    // MARK: - Stats Math

    func testTimeSavedComparesTypingWithSpeaking() {
        // 400 words typed at 40 WPM take 10 minutes; spoken in 3 minutes.
        XCTAssertEqual(StatsMath.timeSaved(words: 400, speakingSeconds: 180, typingWPM: 40), 420, accuracy: 0.001)
        // Faster typists save less.
        XCTAssertEqual(StatsMath.timeSaved(words: 400, speakingSeconds: 180, typingWPM: 80), 120, accuracy: 0.001)
        // Never negative, and zero without words or speed.
        XCTAssertEqual(StatsMath.timeSaved(words: 10, speakingSeconds: 600, typingWPM: 40), 0)
        XCTAssertEqual(StatsMath.timeSaved(words: 0, speakingSeconds: 0, typingWPM: 40), 0)
        XCTAssertEqual(StatsMath.timeSaved(words: 100, speakingSeconds: 10, typingWPM: 0), 0)
    }

    func testSpeakingSpeedAndPercentFaster() {
        XCTAssertEqual(StatsMath.speakingWPM(words: 300, seconds: 120), 150, accuracy: 0.001)
        XCTAssertEqual(StatsMath.speakingWPM(words: 300, seconds: 0), 0)
        XCTAssertEqual(StatsMath.percentFaster(speakingWPM: 150, typingWPM: 40), 275)
        XCTAssertEqual(StatsMath.percentFaster(speakingWPM: 30, typingWPM: 40), 0)
        XCTAssertEqual(StatsMath.percentFaster(speakingWPM: 0, typingWPM: 40), 0)

        var snapshot = StatsSnapshot(dictationCount: 2, wordCount: 300, duration: 120)
        XCTAssertEqual(StatsMath.displayWPM(snapshot), 150, accuracy: 0.001)
        snapshot.wordsPerMinute = 133
        XCTAssertEqual(StatsMath.displayWPM(snapshot), 133)
        XCTAssertEqual(StatsMath.displayWPM(.zero), 0)
    }

    func testDurationText() {
        XCTAssertEqual(StatsMath.durationText(0), "0s")
        XCTAssertEqual(StatsMath.durationText(44.6), "45s")
        XCTAssertEqual(StatsMath.durationText(12 * 60 + 5), "12m")
        XCTAssertEqual(StatsMath.durationText(3600), "1h")
        XCTAssertEqual(StatsMath.durationText(3900), "1h 5m")
        XCTAssertEqual(StatsMath.durationText(-5), "0s")
    }

    func testWeekRangeStartsAtTheWeekStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        // Friday 2026-10-09 15:00 UTC.
        let now = Date(timeIntervalSince1970: 1_791_558_000)
        let start = StatsMath.rangeStart(.week, now: now, calendar: calendar)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_791_158_400)) // Monday 2026-10-05 00:00 UTC
        XCTAssertNil(StatsMath.rangeStart(.allTime, now: now, calendar: calendar))
    }

    func testFingerprintIsDeterministicAndBounded() {
        let first = StatsMath.fingerprint(seed: 1234, count: 48)
        XCTAssertEqual(first.count, 48)
        XCTAssertEqual(first, StatsMath.fingerprint(seed: 1234, count: 48))
        XCTAssertNotEqual(first, StatsMath.fingerprint(seed: 4321, count: 48))
        XCTAssertTrue(first.allSatisfy { (0.15...1).contains($0) })
        XCTAssertEqual(StatsMath.fingerprint(seed: 0, count: 0), [])
        XCTAssertEqual(StatsMath.fingerprint(seed: 0, count: 5).count, 5)
    }

    func testZeroStatsServiceShowsZeros() {
        let service = ZeroStatsService()
        let snapshot = service.snapshot(since: nil)
        XCTAssertEqual(snapshot, .zero)
        XCTAssertEqual(StatsMath.timeSaved(words: snapshot.wordCount, speakingSeconds: snapshot.duration, typingWPM: 40), 0)
        XCTAssertEqual(StatsMath.durationText(0), "0s")
    }

    // MARK: - Share Card

    func testShareCardRendersAPNG() throws {
        let snapshot = StatsSnapshot(dictationCount: 12, wordCount: 1_850, duration: 900, wordsPerMinute: 123, timeSaved: 0)
        let data = try XCTUnwrap(StatsShareCard.pngData(snapshot: snapshot, range: .week, typingWPM: 40))
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, Int(StatsShareCard.size.width * 2))
        XCTAssertEqual(image.pixelsHigh, Int(StatsShareCard.size.height * 2))
    }
}
