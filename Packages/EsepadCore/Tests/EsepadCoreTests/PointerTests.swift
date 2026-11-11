import XCTest
@testable import EsepadCore

final class PointerTests: XCTestCase {
    func testBaseGainSpansBelowAndAboveMacMaximum() {
        XCTAssertEqual(PointerAcceleration(speed: 0, accelerate: false).baseGain, 0.8, accuracy: 0.001)
        XCTAssertEqual(PointerAcceleration(speed: 1, accelerate: false).baseGain, 8.0, accuracy: 0.001)
        XCTAssertGreaterThan(PointerAcceleration(speed: PointerAcceleration.defaultSpeed, accelerate: false).baseGain, 2.5,
                             "既定は速め")
        // つまみは外に出ても飛ばない
        XCTAssertEqual(PointerAcceleration(speed: 5, accelerate: false).baseGain, 8.0, accuracy: 0.001)
        XCTAssertEqual(PointerAcceleration(speed: -1, accelerate: false).baseGain, 0.8, accuracy: 0.001)
    }

    func testGainWithoutAccelerationIsConstant() {
        let a = PointerAcceleration(speed: 0.5, accelerate: false)
        XCTAssertEqual(a.gain(velocity: 0), a.baseGain)
        XCTAssertEqual(a.gain(velocity: 5000), a.baseGain)
    }

    func testAccelerationIsMonotonicAndBounded() {
        let a = PointerAcceleration(speed: 0.5, accelerate: true)
        var prev = 0.0
        for v in stride(from: 0.0, through: 3000, by: 25) {
            let g = a.gain(velocity: v)
            XCTAssertGreaterThanOrEqual(g, prev - 1e-9)
            prev = g
        }
        XCTAssertEqual(a.gain(velocity: 0), a.baseGain * 0.6, accuracy: 1e-9, "ゆっくりは細かく")
        XCTAssertEqual(a.gain(velocity: 100_000), a.baseGain * 2.4, accuracy: 1e-9, "速く払うと遠くへ")
    }

    func testSmootherConservesTotalAndSettles() {
        var s = CursorSmoother(alpha: 0.5)
        s.add(dx: 100, dy: -40)
        var x = 0.0, y = 0.0, ticks = 0
        while !s.isIdle && ticks < 100 {
            let d = s.step(); x += d.dx; y += d.dy; ticks += 1
        }
        XCTAssertEqual(x, 100, accuracy: 1e-9)
        XCTAssertEqual(y, -40, accuracy: 1e-9)
        XCTAssertLessThan(ticks, 15, "240 回/秒なら 60 ミリ秒以内に動き終わる")
    }

    func testSmootherMovesTinyAmountsImmediately() {
        var s = CursorSmoother()
        s.add(dx: 0.4, dy: 0.2)
        let d = s.step()
        XCTAssertEqual(d.dx, 0.4, accuracy: 1e-9)
        XCTAssertTrue(s.isIdle)
    }

    func testSmootherDrainReturnsEverythingPending() {
        var s = CursorSmoother(alpha: 0.5)
        s.add(dx: 50, dy: 10)
        _ = s.step()
        let rest = s.drain()
        XCTAssertEqual(rest.dx, 25, accuracy: 1e-9)
        XCTAssertEqual(rest.dy, 5, accuracy: 1e-9)
        XCTAssertTrue(s.isIdle)
    }

    func testClickCounterCountsUpToThree() {
        var c = ClickCounter(interval: 0.5)
        XCTAssertEqual(c.register(time: 0, x: 10, y: 10), 1)
        XCTAssertEqual(c.register(time: 0.2, x: 12, y: 10), 2)
        XCTAssertEqual(c.register(time: 0.4, x: 12, y: 11), 3)
        XCTAssertEqual(c.register(time: 0.6, x: 12, y: 11), 3, "4 回目は 3 のまま")
        XCTAssertEqual(c.register(time: 2.0, x: 12, y: 11), 1, "間が空いたら 1 に戻る")
        XCTAssertEqual(c.register(time: 2.1, x: 300, y: 300), 1, "離れた場所なら 1")
    }

    func testInertiaDecaysAndTravelsAboutVelocityTimesTau() {
        guard var i = ScrollInertia(vx: 0, vy: 1500) else { return XCTFail() }
        var steps: [Int] = []
        while steps.count < 600 {
            let r = i.step(dt: 1.0 / 120)
            steps.append(r.dy)
            if r.finished { break }
        }
        XCTAssertLessThan(steps.count, 600, "必ず止まる")
        // 1 コマごとは整数に丸めるので、前半と後半で比べる
        let half = steps.count / 2
        XCTAssertGreaterThan(steps[0..<half].reduce(0, +), steps[half...].reduce(0, +) * 2, "だんだん小さくなる")
        XCTAssertEqual(Double(steps.reduce(0, +)), 1500 * 0.32, accuracy: 1500 * 0.32 * 0.1)
    }

    func testInertiaNeedsEnoughVelocity() {
        XCTAssertNil(ScrollInertia(vx: 30, vy: 40))
        XCTAssertNotNil(ScrollInertia(vx: 200, vy: 0))
    }

    func testInertiaKeepsFractionsSoSlowScrollStillMoves() {
        guard var i = ScrollInertia(vx: 0, vy: -200) else { return XCTFail() }
        var total = 0
        for _ in 0..<600 { let r = i.step(dt: 1.0 / 120); total += r.dy; if r.finished { break } }
        XCTAssertLessThan(total, -40)
    }

    func testClampKeepsPointInsideNearestDisplay() {
        let rects = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: -200, width: 1000, height: 800)]
        XCTAssertEqual(DisplayGeometry.clamp(CGPoint(x: 500, y: 500), to: rects), CGPoint(x: 500, y: 500))
        XCTAssertEqual(DisplayGeometry.clamp(CGPoint(x: 1500, y: -100), to: rects), CGPoint(x: 1500, y: -100), "2 枚目の中")
        XCTAssertEqual(DisplayGeometry.clamp(CGPoint(x: -50, y: 300), to: rects), CGPoint(x: 0, y: 300))
        // 1 枚目の下の隙間（2 枚目は上にずれている）
        let p = DisplayGeometry.clamp(CGPoint(x: 1500, y: 700), to: rects)
        XCTAssertTrue(rects.contains { $0.contains(p) })
        XCTAssertEqual(DisplayGeometry.clamp(CGPoint(x: 5, y: 5), to: []), CGPoint(x: 5, y: 5))
    }

    func testVelocityTrackerBasic() {
        var v = VelocityTracker()
        for i in 0...10 { v.add(t: Double(i) * 0.01, x: 0, y: Double(i) * 2) } // 200 pt/s
        let r = v.velocity(at: 0.10)
        XCTAssertEqual(r.vy, 200, accuracy: 1)
        XCTAssertEqual(v.velocity(at: 0.5).vy, 0, "古い")
    }
}
