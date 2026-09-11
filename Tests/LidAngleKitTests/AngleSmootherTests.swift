import XCTest
@testable import LidAngleKit

/// Tests for the filter that turns 10 Hz, coarsely quantised sensor samples into
/// a signal smooth enough to drive a 60 Hz animation.
final class AngleSmootherTests: XCTestCase {

    // MARK: - Median prefilter

    /// The property that matters most in practice: one bad reading must never
    /// reach the screen. Measured on real hardware, the sensor occasionally
    /// reports a wildly wrong value for a single sample.
    func testSingleSampleSpikeIsAbsorbed() {
        var smoother = AngleSmoother(timeConstant: 0.12, snapThreshold: 45)
        let input: [Double] = [50, 50, 50, 12, 50, 50, 50]

        var output: [Double] = []
        for (index, value) in input.enumerated() {
            output.append(smoother.ingest(value, now: Double(index) / 10.0))
        }

        for value in output {
            XCTAssertEqual(value, 50, accuracy: 0.0001,
                           "a lone outlier must not move the smoothed value at all")
        }
    }

    /// A change that persists across samples is real motion, not noise, so it
    /// must get through.
    func testSustainedChangeIsFollowed() {
        var smoother = AngleSmoother(timeConstant: 0.12, snapThreshold: 1000)
        _ = smoother.ingest(50, now: 0)
        _ = smoother.ingest(50, now: 0.1)
        _ = smoother.ingest(50, now: 0.2)

        var last = smoother.value ?? 0
        for step in 3..<30 {
            let value = smoother.ingest(60, now: Double(step) / 10.0)
            XCTAssertGreaterThanOrEqual(value, last - 0.0001, "must approach the target monotonically")
            last = value
        }
        XCTAssertEqual(last, 60, accuracy: 0.5, "should converge on the new value")
    }

    // MARK: - Exponential smoothing

    /// The first sample defines the starting point. Easing in from zero would
    /// make the effect sweep across the screen every time the app launches.
    func testFirstSampleIsAdoptedDirectly() {
        var smoother = AngleSmoother()
        XCTAssertNil(smoother.value)
        XCTAssertEqual(smoother.ingest(97.3, now: 0), 97.3, accuracy: 0.0001)
        XCTAssertEqual(smoother.value ?? 0, 97.3, accuracy: 0.0001)
    }

    /// One time constant should close ~63% of the gap. This is the definition of
    /// the filter, so it pins the behaviour against accidental rewrites.
    func testOneTimeConstantClosesAboutSixtyThreePercent() {
        var smoother = AngleSmoother(timeConstant: 0.12, snapThreshold: 1000)
        _ = smoother.ingest(0, now: 0)
        let value = smoother.ingest(10, now: 0.12)
        XCTAssertEqual(value, 10 * (1 - exp(-1)), accuracy: 0.0001)
    }

    /// The coefficient is derived from elapsed time, not from call count, so a
    /// dropped frame must not change where the value lands.
    func testResultDependsOnElapsedTimeNotCallCount() {
        var coarse = AngleSmoother(timeConstant: 0.12, snapThreshold: 1000)
        _ = coarse.ingest(0, now: 0)
        _ = coarse.ingest(0, now: 0)          // seed the window
        let coarseResult = coarse.advance(to: 0.3)

        var fine = AngleSmoother(timeConstant: 0.12, snapThreshold: 1000)
        _ = fine.ingest(0, now: 0)
        _ = fine.ingest(0, now: 0)
        for step in 1...30 {
            _ = fine.advance(to: Double(step) * 0.01)
        }

        XCTAssertEqual(coarseResult ?? 0, fine.value ?? 0, accuracy: 0.0001,
                       "30 small steps and one big step over the same span must agree")
    }

    /// Between sensor updates the smoother still has to move, otherwise the
    /// 10 Hz steps would be visible at 60 Hz.
    func testAdvanceKeepsEasingWithoutNewSamples() {
        var smoother = AngleSmoother(timeConstant: 0.12, snapThreshold: 1000)
        _ = smoother.ingest(0, now: 0)
        _ = smoother.ingest(100, now: 0.01)
        _ = smoother.ingest(100, now: 0.02)
        let afterIngest = smoother.value ?? 0

        let afterAdvance = smoother.advance(to: 0.2) ?? 0
        XCTAssertGreaterThan(afterAdvance, afterIngest, "advancing time must keep closing the gap")
        XCTAssertLessThanOrEqual(afterAdvance, 100.0001)
    }

    // MARK: - Snap

    /// Waking from sleep can move the angle by a hundred degrees or more.
    /// Easing through that would look like a slow wipe, so it is followed at once.
    func testLargeSustainedJumpSnaps() {
        var smoother = AngleSmoother(timeConstant: 0.12, snapThreshold: 45)
        _ = smoother.ingest(50, now: 0)
        _ = smoother.ingest(50, now: 0.1)
        _ = smoother.ingest(50, now: 0.2)

        // Two samples are needed before the median moves to the new value.
        _ = smoother.ingest(150, now: 0.3)
        let snapped = smoother.ingest(150, now: 0.4)
        XCTAssertEqual(snapped, 150, accuracy: 0.0001, "a jump past the threshold is adopted immediately")
    }

    /// A jump just under the threshold must still be smoothed, not snapped.
    func testJumpBelowThresholdIsSmoothed() {
        var smoother = AngleSmoother(timeConstant: 0.12, snapThreshold: 45)
        _ = smoother.ingest(50, now: 0)
        _ = smoother.ingest(50, now: 0.1)
        _ = smoother.ingest(80, now: 0.2)
        let value = smoother.ingest(80, now: 0.3)
        XCTAssertLessThan(value, 80, "a 30 degree change must ease, not snap")
        XCTAssertGreaterThan(value, 50)
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        var smoother = AngleSmoother()
        _ = smoother.ingest(120, now: 0)
        smoother.reset()
        XCTAssertNil(smoother.value)
        XCTAssertNil(smoother.advance(to: 1))
        XCTAssertEqual(smoother.ingest(30, now: 2), 30, accuracy: 0.0001,
                       "after a reset the next sample is adopted directly again")
    }
}
