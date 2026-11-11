import XCTest
@testable import EsepadCore

/// 指の動きを 1 コマずつ作って、エンジンに渡す。
final class Sim {
    let engine = GestureEngine()
    var t = 100.0
    var touches: [Int: (x: Double, y: Double)] = [:]
    var actions: [GestureAction] = []

    @discardableResult
    func step(_ dt: Double = 0.008) -> [GestureAction] {
        t += dt
        let pts = touches.keys.sorted().map { TouchPoint(id: $0, x: touches[$0]!.x, y: touches[$0]!.y) }
        let a = engine.update(time: t, touches: pts) + engine.tick(time: t)
        actions += a
        return a
    }

    func down(_ id: Int, _ x: Double, _ y: Double, dt: Double = 0.008) { touches[id] = (x, y); step(dt) }
    func move(_ id: Int, _ x: Double, _ y: Double, dt: Double = 0.008) { touches[id] = (x, y); step(dt) }
    func up(_ id: Int, dt: Double = 0.008) { touches[id] = nil; step(dt) }
    func wait(_ s: Double) {
        // 指を動かさずに時間だけ進める（tick だけ）
        var left = s
        while left > 0 { let d = min(0.016, left); t += d; actions += engine.tick(time: t); left -= d }
    }

    var events: [PadEvent] { actions.compactMap { if case let .event(e) = $0 { return e } else { return nil } } }
    var haptics: [Haptic] { actions.compactMap { if case let .haptic(h) = $0 { return h } else { return nil } } }

    var totalMove: (x: Float, y: Float) {
        var x: Float = 0, y: Float = 0
        for e in events { if case let .move(dx, dy, _) = e { x += dx; y += dy } }
        return (x, y)
    }
}

final class GestureTests: XCTestCase {
    func testOneFingerTapClicksWithLightHaptic() {
        let s = Sim()
        s.down(1, 100, 100)
        s.up(1, dt: 0.09)
        XCTAssertEqual(s.events, [.click])
        XCTAssertEqual(s.haptics, [.light])
    }

    func testTapWithSmallWobbleStillClicksAndDoesNotMoveTheCursor() {
        let s = Sim()
        s.down(1, 100, 100)
        s.move(1, 101.5, 99)
        s.move(1, 102, 100.5)
        s.up(1)
        XCTAssertEqual(s.events, [.click])
    }

    func testTouchBetweenTapAndHoldTimeDoesNothing() {
        // 0.28 秒より長く、長押し（0.35 秒）には届かない。誤ってクリックもドラッグもしない
        let s = Sim()
        s.down(1, 100, 100)
        s.wait(0.31)
        s.up(1)
        XCTAssertTrue(s.events.isEmpty)
    }

    func testMovingFingerEmitsMovesAndNoClick() {
        let s = Sim()
        s.down(1, 100, 100)
        for i in 1...20 { s.move(1, 100 + Double(i) * 3, 100 + Double(i)) }
        s.up(1)
        XCTAssertFalse(s.events.contains(.click))
        // 動いた量はひとつも失われない（最初の遊びの分も含めて）
        XCTAssertEqual(s.totalMove.x, 60, accuracy: 0.01)
        XCTAssertEqual(s.totalMove.y, 20, accuracy: 0.01)
    }

    func testMoveCarriesFrameTime() {
        let s = Sim()
        s.down(1, 0, 0)
        s.move(1, 10, 0, dt: 0.016)
        guard case let .move(_, _, dt)? = s.events.first else { return XCTFail() }
        XCTAssertEqual(dt, 16, accuracy: 0.5)
    }

    func testTwoFingerTapIsRightClick() {
        let s = Sim()
        s.down(1, 100, 100)
        s.down(2, 140, 100, dt: 0.03)
        s.up(1, dt: 0.06)
        s.up(2, dt: 0.01)
        XCTAssertEqual(s.events, [.rightClick])
        XCTAssertEqual(s.haptics, [.medium])
    }

    func testSecondFingerLandingLateIsNotARightClick() {
        let s = Sim()
        s.down(1, 100, 100)
        s.wait(0.2)
        s.down(2, 140, 100)
        s.up(2, dt: 0.03)
        s.up(1, dt: 0.01)
        XCTAssertTrue(s.events.isEmpty)
    }

    func testTwoFingerScrollHasPhasesAndVelocity() {
        let s = Sim()
        s.down(1, 100, 100)
        s.down(2, 140, 100, dt: 0.02)
        for i in 1...15 { s.move(1, 100, 100 + Double(i) * 6); s.move(2, 140, 100 + Double(i) * 6) }
        s.up(2, dt: 0.004)
        s.up(1, dt: 0.004)
        let scrolls = s.events.compactMap { e -> (ScrollPhase, Float, Float)? in
            if case let .scroll(p, dx, dy) = e { return (p, dx, dy) } else { return nil }
        }
        XCTAssertEqual(scrolls.first?.0, .began)
        XCTAssertEqual(scrolls.last?.0, .ended)
        XCTAssertEqual(scrolls.filter { $0.0 == .ended }.count, 1)
        // 1 コマ 6pt / 約 16ms(2 回の step) ≒ 下向きに速い
        XCTAssertGreaterThan(scrolls.last!.2, 200)
        XCTAssertEqual(scrolls.dropLast().reduce(Float(0)) { $0 + $1.2 }, 90, accuracy: 0.01, "動いた量はそのまま届く")
        XCTAssertFalse(s.events.contains(.rightClick))
    }

    func testScrollThatStopsBeforeLiftingHasNoMomentum() {
        let s = Sim()
        s.down(1, 100, 100)
        s.down(2, 140, 100, dt: 0.02)
        for i in 1...10 { s.move(1, 100, 100 + Double(i) * 6); s.move(2, 140, 100 + Double(i) * 6) }
        s.wait(0.3)
        s.up(2); s.up(1)
        guard case let .scroll(.ended, _, vy)? = s.events.last else { return XCTFail() }
        XCTAssertEqual(vy, 0)
    }

    func testAddingSecondFingerWhileMovingSwitchesToScrollWithoutJump() {
        let s = Sim()
        s.down(1, 100, 100)
        for i in 1...5 { s.move(1, 100 + Double(i) * 5, 100) }
        let before = s.events.count
        s.down(2, 300, 300)   // 遠くに 2 本目。重心が大きく変わるが、飛ばない
        s.move(1, 130, 100); s.move(2, 300, 300)
        let tail = Array(s.events[before...])
        XCTAssertEqual(tail.first, .scroll(phase: .began, dx: 0, dy: 0), "動いている途中でも、スクロールは「始まり」から出す")
        for e in tail {
            if case let .scroll(_, dx, dy) = e { XCTAssertLessThan(abs(dx) + abs(dy), 30, "重心の基準を取り直すので、スクロールが一気に飛ばない") }
            if case .move = e { XCTFail("2 本指の間はカーソルを動かさない") }
        }
    }

    func testLiftingOneFingerAfterScrollDoesNotMoveCursor() {
        let s = Sim()
        s.down(1, 100, 100)
        s.down(2, 140, 100, dt: 0.02)
        for i in 1...6 { s.move(1, 100, 100 + Double(i) * 5); s.move(2, 140, 100 + Double(i) * 5) }
        s.up(2)
        let count = s.events.count
        s.move(1, 200, 300); s.move(1, 260, 340)
        XCTAssertEqual(s.events.count, count, "残った 1 本の指ではカーソルを動かさない")
        XCTAssertTrue(s.events.contains { if case .scroll(.ended, _, _) = $0 { return true } else { return false } })
    }

    func testHoldThenMoveIsDragWithHapticAndEnd() {
        let s = Sim()
        s.down(1, 100, 100)
        s.wait(0.40)
        XCTAssertEqual(s.events, [.dragBegin])
        XCTAssertEqual(s.haptics, [.heavy])
        for i in 1...10 { s.move(1, 100 + Double(i) * 4, 100) }
        s.up(1)
        XCTAssertEqual(s.events.first, .dragBegin)
        XCTAssertEqual(s.events.last, .dragEnd)
        XCTAssertEqual(s.totalMove.x, 40, accuracy: 0.01)
        XCTAssertFalse(s.events.contains(.click))
    }

    func testHoldAndReleaseWithoutMovingEndsTheDrag() {
        let s = Sim()
        s.down(1, 100, 100)
        s.wait(0.4)
        s.up(1)
        XCTAssertEqual(s.events, [.dragBegin, .dragEnd])
    }

    func testMovingBeforeHoldTimeDoesNotStartDrag() {
        let s = Sim()
        s.down(1, 100, 100)
        s.move(1, 130, 100)
        s.wait(0.5)
        XCTAssertFalse(s.events.contains(.dragBegin))
    }

    func testExtraFingerDuringDragIsIgnoredAndPrimaryLiftEndsIt() {
        let s = Sim()
        s.down(1, 100, 100)
        s.wait(0.4)
        s.down(2, 300, 300)
        s.move(1, 110, 100)
        XCTAssertEqual(s.totalMove.x, 10, accuracy: 0.01)
        s.up(1)
        XCTAssertEqual(s.events.last, .dragEnd)
        s.move(2, 320, 320)
        XCTAssertEqual(s.events.last, .dragEnd, "残りの指では動かさない")
    }

    /// 3 本指を (dx, dy) だけ 12 コマで動かして離す。出た操作を返す
    private func swipeEvents(dx: Double, dy: Double) -> [PadEvent] {
        let s = Sim()
        s.down(1, 300, 200); s.down(2, 340, 200, dt: 0.01); s.down(3, 380, 200, dt: 0.01)
        for i in 1...12 {
            let f = Double(i) / 12
            s.move(1, 300 + dx * f, 200 + dy * f); s.move(2, 340 + dx * f, 200 + dy * f); s.move(3, 380 + dx * f, 200 + dy * f)
        }
        s.up(1); s.up(2); s.up(3)
        return s.events
    }

    private func isSwipeDrag(_ e: PadEvent, _ phase: ScrollPhase) -> Bool {
        if case let .swipeDrag(p, _, _) = e { return p == phase } else { return false }
    }

    func testThreeFingerSwipeFollowsTheFingers() {
        let ev = swipeEvents(dx: -120, dy: 5)
        XCTAssertTrue(isSwipeDrag(ev.first!, .began))
        XCTAssertTrue(isSwipeDrag(ev.last!, .ended))
        XCTAssertGreaterThan(ev.filter { isSwipeDrag($0, .changed) }.count, 3, "動いている間、途中の動きを送り続ける")
        // 始まりの量 + 途中の量 = 指が動いた量（ひとつも失わない）
        var total: Float = 0
        for e in ev { if case let .swipeDrag(p, dx, _) = e, p != .ended { total += dx } }
        XCTAssertEqual(total, -120, accuracy: 0.01)
        // 離す直前の速さは、動いてきた向き
        if case let .swipeDrag(.ended, vx, _) = ev.last! { XCTAssertLessThan(vx, 0) } else { XCTFail() }
    }

    func testThreeFingerSwipeDirections() {
        func total(_ ev: [PadEvent]) -> (Float, Float) {
            var x: Float = 0, y: Float = 0
            for e in ev { if case let .swipeDrag(p, dx, dy) = e, p != .ended { x += dx; y += dy } }
            return (x, y)
        }
        XCTAssertGreaterThan(total(swipeEvents(dx: 120, dy: -5)).0, 100)
        let up = total(swipeEvents(dx: 5, dy: -120))
        XCTAssertLessThan(up.1, -100)
        XCTAssertTrue(swipeEvents(dx: 5, dy: 120).isEmpty, "下向きは使わない")
        XCTAssertTrue(swipeEvents(dx: 6, dy: 6).isEmpty, "ほんの少し・斜めでは始めない")
        XCTAssertTrue(swipeEvents(dx: 40, dy: 40).isEmpty, "斜めは始めない")
    }

    func testThreeFingerSwipeBeginsOnceAndNotRightClickOrScroll() {
        let s = Sim()
        s.down(1, 300, 200); s.down(2, 340, 200, dt: 0.01); s.down(3, 380, 200, dt: 0.01)
        for i in 1...30 { let x = -Double(i) * 8; s.move(1, 300 + x, 200); s.move(2, 340 + x, 200); s.move(3, 380 + x, 200) }
        XCTAssertEqual(s.events.filter { isSwipeDrag($0, .began) }.count, 1)
        XCTAssertTrue(s.events.allSatisfy { if case .swipeDrag = $0 { return true } else { return false } })
        XCTAssertEqual(s.haptics, [.soft])
    }

    func testThreeFingerSwipeEndsWhenOneFingerLeaves() {
        let s = Sim()
        s.down(1, 300, 200); s.down(2, 340, 200, dt: 0.01); s.down(3, 380, 200, dt: 0.01)
        for i in 1...10 { let x = -Double(i) * 10; s.move(1, 300 + x, 200); s.move(2, 340 + x, 200); s.move(3, 380 + x, 200) }
        s.up(3)
        XCTAssertTrue(isSwipeDrag(s.events.last!, .ended))
        let count = s.events.count
        s.move(1, 150, 200); s.up(1); s.up(2)
        XCTAssertEqual(s.events.count, count, "終わったあとは、何も送らない")
    }

    func testFourFingersAreIgnored() {
        let s = Sim()
        s.down(1, 100, 100); s.down(2, 140, 100, dt: 0.01); s.down(3, 180, 100, dt: 0.01); s.down(4, 220, 100, dt: 0.01)
        for i in 1...10 { for id in 1...4 { s.move(id, 100 + Double(id) * 40 - 160 + Double(i) * 10, 100) } }
        s.up(1); s.up(2); s.up(3); s.up(4)
        XCTAssertTrue(s.events.isEmpty)
    }

    func testTheNextGestureWorksAfterEverythingWasLifted() {
        let s = Sim()
        s.down(1, 100, 100); s.down(2, 140, 100, dt: 0.01); s.down(3, 180, 100, dt: 0.01); s.down(4, 220, 100, dt: 0.01)
        s.up(1); s.up(2); s.up(3); s.up(4)
        XCTAssertTrue(s.engine.isIdle)
        s.down(1, 50, 50)
        s.up(1, dt: 0.05)
        XCTAssertEqual(s.events, [.click])
    }

    func testFingerSwapDuringCursorMoveDoesNotJump() {
        let s = Sim()
        s.down(1, 100, 100)
        for i in 1...4 { s.move(1, 100 + Double(i) * 5, 100) }
        let n = s.events.count
        // 1 のかわりに 2 が遠くに現れた（同じコマで入れ替わり）
        s.touches[1] = nil
        s.touches[2] = (400, 300)
        s.step()
        XCTAssertEqual(s.events.count, n, "入れ替わりのコマでは動かさない")
    }
}
