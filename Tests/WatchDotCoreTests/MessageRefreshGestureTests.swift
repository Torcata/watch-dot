import XCTest
@testable import WatchDotCore

final class MessageRefreshGestureTests: XCTestCase {
    func testPullAndHoldArmsUntilReleaseAndReleaseOnlyFiresOnce() {
        var gesture = MessageRefreshGestureState()
        gesture.begin(enabled: true)
        gesture.update(distance: 40)
        gesture.update(distance: 40)
        XCTAssertTrue(gesture.isTracking)
        XCTAssertTrue(gesture.isArmed)
        XCTAssertEqual(gesture.pullDistance, 40)
        XCTAssertTrue(gesture.release())
        XCTAssertFalse(gesture.release())
        XCTAssertFalse(gesture.isArmed)
        XCTAssertEqual(gesture.pullDistance, 0)
    }

    func testShortPullDoesNotRefresh() {
        var gesture = MessageRefreshGestureState()
        gesture.begin(enabled: true)
        gesture.update(distance: 15)
        XCTAssertFalse(gesture.release())
    }

    func testScrollingBeforeEndOrInOppositeDirectionDoesNotRefresh() {
        var gesture = MessageRefreshGestureState()
        gesture.begin(enabled: true)
        gesture.update(distance: -200)
        gesture.update(distance: 0)
        XCTAssertEqual(gesture.pullDistance, 0)
        XCTAssertFalse(gesture.release())
    }

    func testNativeBounceBeforeReleaseDoesNotLoseArmedRefresh() {
        var gesture = MessageRefreshGestureState()
        gesture.begin(enabled: true)
        gesture.update(distance: 40)
        gesture.update(distance: 0)
        XCTAssertTrue(gesture.release())
        gesture.update(distance: 60)
        XCTAssertFalse(gesture.release())
    }

    func testDisabledGestureDuringExistingQueryDoesNotRefreshAgain() {
        var gesture = MessageRefreshGestureState()
        gesture.begin(enabled: false)
        gesture.update(distance: 100)
        XCTAssertFalse(gesture.isArmed)
        XCTAssertFalse(gesture.release())
    }

    func testCancellationDisarmsAndNextPullCanRefresh() {
        var gesture = MessageRefreshGestureState()
        gesture.begin(enabled: true)
        gesture.update(distance: 40)
        gesture.cancel()
        XCTAssertFalse(gesture.release())
        gesture.begin(enabled: true)
        gesture.update(distance: 40)
        XCTAssertTrue(gesture.release())
    }

    func testLegacyGestureUsesFingerDistanceThreshold() {
        var gesture = MessageRefreshGestureState()
        gesture.begin(enabled: true, threshold: 56)
        gesture.update(distance: 30)
        XCTAssertFalse(gesture.isArmed)
        gesture.update(distance: 60)
        XCTAssertTrue(gesture.release())
    }
}
