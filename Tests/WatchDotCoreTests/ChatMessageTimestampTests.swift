import XCTest
@testable import WatchDotCore

final class ChatMessageTimestampTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    func testTodayShowsOnlyLocalTime() throws {
        // The UTC dates differ, but both timestamps are October 4 on the watch.
        let message = ChatMessage(role: .assistant, text: "Respuesta",
                                  createdAt: try date("2026-10-04T21:30:00Z"))
        XCTAssertEqual(message.timestampLabel(relativeTo: try date("2026-10-05T02:00:00Z"),
            calendar: calendar, locale: Locale(identifier: "es_CL@hours=h23")), "18:30")
    }

    func testPreviousLocalDayShowsLowercaseMonthDayAndTime() throws {
        // Only one hour elapsed, but midnight passed in the watch's time zone.
        let message = ChatMessage(role: .assistant, text: "Respuesta",
                                  createdAt: try date("2026-10-05T02:30:00Z"))
        XCTAssertEqual(message.timestampLabel(relativeTo: try date("2026-10-05T03:30:00Z"),
            calendar: calendar, locale: Locale(identifier: "es_CL@hours=h23")), "oct-04 23:30")
    }

    func testPreviousYearAlsoShowsDateWithTwoDigitDay() throws {
        let message = ChatMessage(role: .user, text: "Mensaje",
                                  createdAt: try date("2025-10-04T12:05:00Z"))
        XCTAssertEqual(message.timestampLabel(relativeTo: try date("2026-10-04T21:30:00Z"),
            calendar: calendar, locale: Locale(identifier: "es_CL@hours=h23")), "oct-04 09:05")
    }
}
