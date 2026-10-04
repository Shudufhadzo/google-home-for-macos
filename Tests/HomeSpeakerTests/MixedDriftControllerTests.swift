import XCTest
@testable import HomeSpeaker

final class MixedDriftControllerTests: XCTestCase {
    func testCastSeekBiasLearnsAnEarlierTargetWhenReceiverRemainsAhead() {
        var subject = MixedDriftController()
        XCTAssertNil(update(&subject, time: 100, drift: -0.2))
        XCTAssertNil(update(&subject, time: 101, drift: -0.2))
        XCTAssertEqual(update(&subject, time: 102, drift: -0.2), .cast(10))
        XCTAssertNil(update(&subject, time: 106, drift: -0.2))
        XCTAssertNil(update(&subject, time: 107, drift: -0.2))
        XCTAssertEqual(update(&subject, time: 108, drift: -0.2), .cast(9.93), "Damp feedback from receiver seek bias instead of issuing the same ineffective target forever")
    }
    private func update(_ controller: inout MixedDriftController, time: Double, drift: Double,
                        offset: Double = 0, target: Double? = 10) -> MixedDriftController.Correction? {
        controller.target(assessment: .init(target: target, difference: drift, castTarget: drift < 0 ? target : nil, note: ""),
                          sampleTimes: ["speaker": time, "airplay": time], offset: offset, now: time)
    }

    func testTVRemainsContinuousWhenCastCanSeekInEitherDirection() {
        var subject = MixedDriftController()
        for time in [100.0, 101] {
            XCTAssertNil(subject.target(assessment: .init(target: 10, difference: 0.4, castTarget: 10.4, note: ""),
                                        sampleTimes: ["speaker": time, "tv": time], offset: 0, now: time))
        }
        XCTAssertEqual(subject.target(assessment: .init(target: 10, difference: 0.4, castTarget: 10.4, note: ""),
                                      sampleTimes: ["speaker": 102, "tv": 102], offset: 0, now: 102), .cast(10.4))
    }

    func testPersistentSubQuarterSecondDriftTriggersCorrectionButRepeatedSamplesDoNot() {
        var subject = MixedDriftController()
        XCTAssertNil(update(&subject, time: 100, drift: 0.12))
        for _ in 0..<20 { XCTAssertNil(update(&subject, time: 100, drift: 0.12)) }
        XCTAssertNil(update(&subject, time: 100.5, drift: 0.12))
        XCTAssertEqual(update(&subject, time: 101, drift: 0.12), .airPlay(10))
        XCTAssertNil(update(&subject, time: 101.5, drift: -0.3), "Let the seek settle before correcting again")
        XCTAssertNil(update(&subject, time: 105, drift: -0.3))
        XCTAssertNil(update(&subject, time: 105.5, drift: -0.3))
        XCTAssertEqual(update(&subject, time: 106, drift: -0.3), .cast(10), "When TV buffering prevents catching up, delay the faster Cast receiver")
    }

    func testSmallErrorOffsetNoiseAndMissingWindowsDoNotCauseRepeatedSeeks() {
        var subject = MixedDriftController()
        for index in 0..<8 { XCTAssertNil(update(&subject, time: 100 + Double(index), drift: 0.07)) }
        XCTAssertNil(update(&subject, time: 110, drift: 0.15))
        XCTAssertNil(update(&subject, time: 111, drift: 0.15, target: nil))
        XCTAssertNil(update(&subject, time: 112, drift: 0.15))
        XCTAssertNil(update(&subject, time: 113, drift: 0.15))
        XCTAssertEqual(update(&subject, time: 114, drift: 0.15), .airPlay(10))
        subject.reset()
        for index in 0..<8 { XCTAssertNil(update(&subject, time: 120 + Double(index), drift: 0.3, offset: 0.3)) }
    }
}
