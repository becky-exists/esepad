import XCTest
@testable import EsepadCore

/// 3 版目: 指についてくる 3 本指のスワイプ、縦置きのマウスの形
final class DockSwipeDriverTests: XCTestCase {
    private func steps(_ o: [DockSwipeDriver.Output]) -> [DockSwipeDriver.Step] {
        o.compactMap { if case let .step(s) = $0 { return s } else { return nil } }
    }

    func testFluidHorizontalFollowsFingerAndSignMatchesDirection() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        let b = steps(d.begin(dx: -36, dy: 2))
        XCTAssertEqual(b.map(\.phase), [1, 2])
        XCTAssertEqual(b[0].progress, 0)
        XCTAssertEqual(b[1].progress, -0.1, accuracy: 1e-9, "左へ払う（右のデスクトップへ）はマイナス")
        let c = steps(d.changed(dx: -72, dy: 0))
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].phase, 2)
        XCTAssertEqual(c[0].progress, -0.3, accuracy: 1e-9)
        // 戻すと progress も戻る（指についてくる）
        XCTAssertEqual(steps(d.changed(dx: 36, dy: 0))[0].progress, -0.2, accuracy: 1e-9)
    }

    func testReleaseFarEnoughCommits() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = d.begin(dx: 20, dy: 0)
        _ = d.changed(dx: 200, dy: 0)   // 220pt = 0.61
        let e = steps(d.ended(vx: 0, vy: 0))
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].phase, 4)
        XCTAssertEqual(e[0].velX, 9999, "進めた向きのまま切り替える")
        XCTAssertNil(d.axis)
    }

    func testReleaseShortAndSlowSnapsBack() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = d.begin(dx: -20, dy: 0)
        _ = d.changed(dx: -60, dy: 0)   // 0.22
        let e = steps(d.ended(vx: -100, vy: 0))
        XCTAssertEqual(e[0].phase, 4)
        XCTAssertEqual(e[0].velX, 0, "切り替えない時は速さをつけない")
    }

    func testFlickCommitsEvenWhenShort() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = d.begin(dx: -20, dy: 0)
        _ = d.changed(dx: -30, dy: 0)   // 50pt = 0.14
        XCTAssertEqual(steps(d.ended(vx: -900, vy: 0))[0].velX, -9999)
    }

    func testFlickAgainstTheDirectionDoesNotCommit() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = d.begin(dx: -20, dy: 0)
        _ = d.changed(dx: -30, dy: 0)
        XCTAssertEqual(steps(d.ended(vx: 900, vy: 0))[0].velX, 0)
    }

    func testProgressIsClampedToOneDesktop() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = d.begin(dx: 20, dy: 0)
        XCTAssertEqual(steps(d.changed(dx: 2000, dy: 0))[0].progress, 1)
        // 行き過ぎた分は溜めない。少し戻せばすぐ下がる
        XCTAssertEqual(steps(d.changed(dx: -36, dy: 0))[0].progress, 0.9, accuracy: 1e-9)
    }

    func testShortcutModeCommitsOnceOnRelease() {
        var d = DockSwipeDriver(fluidHorizontal: false, fluidVertical: false)
        XCTAssertTrue(d.begin(dx: -20, dy: 0).isEmpty)
        XCTAssertTrue(d.changed(dx: -60, dy: 0).isEmpty, "近道の時は、動いている間は何も出さない")
        XCTAssertEqual(d.ended(vx: -50, vy: 0), [.commit(.left)])
    }

    func testShortcutModeShortMoveDoesNothing() {
        var d = DockSwipeDriver(fluidHorizontal: false, fluidVertical: false)
        _ = d.begin(dx: 20, dy: 0)
        _ = d.changed(dx: 20, dy: 0)    // 40pt = 0.11
        XCTAssertTrue(d.ended(vx: 0, vy: 0).isEmpty)
    }

    func testVerticalUpFluidAndShortcut() {
        var f = DockSwipeDriver(fluidHorizontal: true, fluidVertical: true)
        let b = steps(f.begin(dx: 3, dy: -40))
        XCTAssertEqual(b.map(\.motion), [2, 2])
        XCTAssertEqual(b[1].progress, 40 / 360.0, accuracy: 1e-9, "上へはプラス")
        _ = f.changed(dx: 0, dy: -200)
        XCTAssertEqual(steps(f.ended(vx: 0, vy: 0))[0].velY, 9999)

        var s = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = s.begin(dx: 3, dy: -40)
        _ = s.changed(dx: 0, dy: -60)
        XCTAssertEqual(s.ended(vx: 0, vy: 0), [.commit(.up)], "縦だけ近道の時は、横は段階つきのまま")
    }

    func testVerticalDoesNotGoNegative() {
        var d = DockSwipeDriver(fluidHorizontal: false, fluidVertical: true)
        _ = d.begin(dx: 0, dy: -40)
        XCTAssertEqual(steps(d.changed(dx: 0, dy: 500))[0].progress, 0, "下向きには行かない")
    }

    func testAbortClosesAnOpenGestureWithoutCommitting() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = d.begin(dx: -200, dy: 0)
        let e = steps(d.abort())
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].phase, 4)
        XCTAssertEqual(e[0].velX, 0)
        XCTAssertTrue(d.abort().isEmpty, "二重に閉じない")
    }

    func testDemotedSessionCommitsInsteadOfStepping() {
        var d = DockSwipeDriver(fluidHorizontal: true, fluidVertical: false)
        _ = d.begin(dx: -20, dy: 0)
        d.demoteToCommit()
        XCTAssertTrue(d.changed(dx: -200, dy: 0).isEmpty)
        XCTAssertEqual(d.ended(vx: 0, vy: 0), [.commit(.left)])
    }
}

final class SwipeDragWireTests: XCTestCase {
    func testRoundTrip() {
        let events: [PadEvent] = [
            .swipeDrag(phase: .began, dx: -12, dy: 1.5),
            .swipeDrag(phase: .changed, dx: 4.25, dy: -0.5),
            .swipeDrag(phase: .ended, dx: -1800, dy: 40),
        ]
        for e in events { XCTAssertEqual(PadEvent.decode(e.encode()), e) }
    }

    func testRejectsBadValues() {
        XCTAssertNil(PadEvent.decode(PadEvent.swipeDrag(phase: .changed, dx: 9000, dy: 0).encode()))
        XCTAssertNotNil(PadEvent.decode(PadEvent.swipeDrag(phase: .ended, dx: 9000, dy: 0).encode()))
        var w = ByteWriter(9); w.u8(1); w.f32(.nan); w.f32(0)
        XCTAssertNil(PadEvent.decode(w.bytes))
        XCTAssertNil(PadEvent.decode([10, 0, 1]), "使わなくなった種類は受け取らない")
    }

    func testQueueMergesSwipeDragChangedOnly() {
        var q = OutboundQueue()
        q.push(.swipeDrag(phase: .began, dx: 1, dy: 0))
        q.push(.swipeDrag(phase: .changed, dx: 2, dy: 0))
        q.push(.swipeDrag(phase: .changed, dx: 3, dy: 1))
        q.push(.swipeDrag(phase: .ended, dx: 100, dy: 0))
        XCTAssertEqual(q.pop(), .swipeDrag(phase: .began, dx: 1, dy: 0))
        XCTAssertEqual(q.pop(), .swipeDrag(phase: .changed, dx: 5, dy: 1))
        XCTAssertEqual(q.pop(), .swipeDrag(phase: .ended, dx: 100, dy: 0))
        XCTAssertNil(q.pop())
    }
}

/// 横置き・縦置き共通の、トン→押したまま滑らせるドラッグ
final class TapDragTests: XCTestCase {
    func testTapThenImmediateSlideIsDragWithHeavyHaptic() {
        let s = Sim()
        s.down(1, 100, 100); s.up(1, dt: 0.06)        // 1 回目のトン
        XCTAssertEqual(s.events, [.click], "1 回目のトンは、待たずにその場でクリック")
        s.down(1, 102, 100, dt: 0.12)                  // 0.12 秒後に置いて
        for i in 1...6 { s.move(1, 102 + Double(i) * 5, 100) }
        XCTAssertEqual(s.events[1], .dragBegin, "動いた瞬間にドラッグ（長押しを待たない）")
        XCTAssertEqual(s.haptics, [.light, .heavy])
        var x: Float = 0
        for e in s.events { if case let .move(dx, _, _) = e { x += dx } }
        XCTAssertEqual(x, 30, accuracy: 0.01, "動いた量はひとつも失わない")
        s.up(1)
        XCTAssertEqual(s.events.last, .dragEnd)
        XCTAssertEqual(s.haptics.last, .release)
    }

    func testSecondTapWithoutMovingIsStillAClick_SoMacCountsDoubleClick() {
        let s = Sim()
        s.down(1, 100, 100); s.up(1, dt: 0.06)
        s.down(1, 101, 100, dt: 0.1); s.up(1, dt: 0.06)
        XCTAssertEqual(s.events, [.click, .click], "トントンは click が 2 回（Mac が回数を数えてダブルクリックにする）")
    }

    func testTapThenHoldStillWorksAsHoldDrag() {
        let s = Sim()
        s.down(1, 100, 100); s.up(1, dt: 0.06)
        s.down(1, 100, 100, dt: 0.1)
        s.wait(0.4)
        XCTAssertEqual(s.events, [.click, .dragBegin])
    }

    func testSlideAfterTooLongAPauseIsPlainCursorMove() {
        let s = Sim()
        s.down(1, 100, 100); s.up(1, dt: 0.06)
        s.down(1, 100, 100, dt: 0.5)
        for i in 1...6 { s.move(1, 100 + Double(i) * 5, 100) }
        XCTAssertFalse(s.events.contains(.dragBegin))
    }

    func testSlideFarFromTheFirstTapIsPlainCursorMove() {
        let s = Sim()
        s.down(1, 100, 100); s.up(1, dt: 0.06)
        s.down(1, 400, 300, dt: 0.1)
        for i in 1...6 { s.move(1, 400 + Double(i) * 5, 300) }
        XCTAssertFalse(s.events.contains(.dragBegin), "離れた所に置いたら、ただのクリックのあとの移動")
    }

    func testPlainSlideWithoutATapBeforeIsCursor() {
        let s = Sim()
        s.down(1, 100, 100)
        for i in 1...6 { s.move(1, 100 + Double(i) * 5, 100) }
        XCTAssertFalse(s.events.contains(.dragBegin))
    }

    func testTwoFingerTapDoesNotArmTapDrag() {
        let s = Sim()
        s.down(1, 100, 100); s.down(2, 140, 100, dt: 0.03); s.up(1, dt: 0.05); s.up(2, dt: 0.01)
        XCTAssertEqual(s.events, [.rightClick])
        s.down(1, 100, 100, dt: 0.1)
        for i in 1...6 { s.move(1, 100 + Double(i) * 5, 100) }
        XCTAssertFalse(s.events.contains(.dragBegin), "右クリックのあとはドラッグにしない")
    }

    func testSecondFingerAddedTurnsItIntoScrollNotDrag() {
        let s = Sim()
        s.down(1, 100, 100); s.up(1, dt: 0.06)
        s.down(1, 100, 100, dt: 0.1); s.down(2, 140, 100, dt: 0.02)
        for i in 1...6 { s.move(1, 100, 100 + Double(i) * 5); s.move(2, 140, 100 + Double(i) * 5) }
        XCTAssertFalse(s.events.contains(.dragBegin))
        XCTAssertTrue(s.events.contains { if case .scroll(.began, _, _) = $0 { return true } else { return false } })
    }
}

/// 縦に置いた時の「マウスの形」。面は 400 x 800。上の帯は 144pt（18%）、右端の帯は 370〜400
final class MouseShapeTests: XCTestCase {
    func sim() -> Sim {
        let s = Sim()
        s.engine.mouseLayout = MouseLayout(width: 400, height: 800)
        return s
    }

    func testLeftHalfTapIsLeftClickAndRightHalfTapIsRightClickAnywhere() {
        for y in [20.0, 300.0, 780.0] {
            let l = sim()
            l.down(1, 100, y); l.up(1, dt: 0.06)
            XCTAssertEqual(l.events, [.click], "y=\(y) の左半分")
            XCTAssertEqual(l.haptics, [.light])
            let r = sim()
            r.down(1, 300, y); r.up(1, dt: 0.06)
            XCTAssertEqual(r.events, [.rightClick], "y=\(y) の右半分")
            XCTAssertEqual(r.haptics, [.medium], "右は強めに震えて、どちらを押したか分かる")
        }
    }

    func testCenterLineBoundary() {
        let s = sim()
        s.down(1, 199.9, 400); s.up(1, dt: 0.06)
        s.down(1, 200, 400, dt: 0.5); s.up(1, dt: 0.06)
        XCTAssertEqual(s.events, [.click, .rightClick])
    }

    func testRightEdgeStripTapIsRightClick() {
        let s = sim()
        s.down(1, 390, 400); s.up(1, dt: 0.06)
        XCTAssertEqual(s.events, [.rightClick])
    }

    func testSwipingFromEitherSideMovesTheCursorAndNeverClicks() {
        for startX in [300.0, 100.0] {
            let s = sim()
            s.down(1, startX, 50)
            for i in 1...20 { s.move(1, startX - Double(i) * 3, 50 + Double(i)) }
            s.up(1)
            XCTAssertFalse(s.events.contains(.rightClick))
            XCTAssertFalse(s.events.contains(.click))
            var x: Float = 0
            for e in s.events { if case let .move(dx, _, _) = e { x += dx } }
            XCTAssertEqual(x, -60, accuracy: 0.01, "どちら側から始めても、面ぜんぶでカーソルが動く")
        }
    }

    func testSlowTouchIsNotAClickOnEitherSide() {
        for x in [100.0, 300.0] {
            let s = sim()
            s.down(1, x, 400)
            s.wait(0.31)
            s.up(1)
            XCTAssertTrue(s.events.isEmpty, "置いてすぐ離した時だけクリック")
        }
    }

    func testSmallWobbleStillClicks() {
        let s = sim()
        s.down(1, 100, 400); s.move(1, 102, 401); s.move(1, 101, 399); s.up(1, dt: 0.05)
        XCTAssertEqual(s.events, [.click])
        let r = sim()
        r.down(1, 300, 400); r.move(1, 302, 401); r.up(1, dt: 0.05)
        XCTAssertEqual(r.events, [.rightClick])
    }

    func testLandscapeHasNoSidesEverySingleTapIsLeftClick() {
        let s = Sim()   // mouseLayout なし = 横置き
        s.down(1, 700, 50); s.up(1, dt: 0.06)
        XCTAssertEqual(s.events, [.click])
        XCTAssertEqual(s.haptics, [.light])
        XCTAssertNil(s.engine.pressedSide)
    }

    func testTwoFingerTapIsStillRightClickInMouseShape() {
        let s = sim()
        s.down(1, 100, 400); s.down(2, 140, 400, dt: 0.03); s.up(1, dt: 0.06); s.up(2, dt: 0.01)
        XCTAssertEqual(s.events, [.rightClick])
    }

    func testDoubleTapOnEachSideSendsTwoClicksOfThatSide() {
        let l = sim()
        l.down(1, 100, 400); l.up(1, dt: 0.05); l.down(1, 101, 400, dt: 0.1); l.up(1, dt: 0.05)
        XCTAssertEqual(l.events, [.click, .click])
        let r = sim()
        r.down(1, 300, 400); r.up(1, dt: 0.05); r.down(1, 301, 400, dt: 0.1); r.up(1, dt: 0.05)
        XCTAssertEqual(r.events, [.rightClick, .rightClick])
    }

    func testTapThenSlideIsLeftButtonDragFromEitherSide() {
        // 左でトン → 左で滑らせる
        let a = sim()
        a.down(1, 100, 500); a.up(1, dt: 0.05); a.down(1, 100, 500, dt: 0.1)
        for i in 1...6 { a.move(1, 100 + Double(i) * 5, 500) }
        XCTAssertEqual(a.events.filter { $0 == .dragBegin }.count, 1)
        // 左でトン → 右側に置いて滑らせる（近ければドラッグ）
        let b = sim()
        b.down(1, 180, 500); b.up(1, dt: 0.05); b.down(1, 230, 500, dt: 0.1)
        for i in 1...6 { b.move(1, 230 + Double(i) * 5, 500) }
        XCTAssertEqual(b.events.filter { $0 == .dragBegin }.count, 1, "右側で始めても、左ボタンのドラッグ")
        XCTAssertFalse(b.events.contains(.rightClick))
        // 右でトン（右クリック）のあとは、ドラッグにしない
        let c = sim()
        c.down(1, 300, 500); c.up(1, dt: 0.05); c.down(1, 300, 500, dt: 0.1)
        for i in 1...6 { c.move(1, 300 + Double(i) * 5, 500) }
        XCTAssertFalse(c.events.contains(.dragBegin))
        // 右側で始めて、そのまま長押ししても左ボタンのドラッグ
        let d = sim()
        d.down(1, 300, 500)
        d.wait(0.4)
        XCTAssertEqual(d.events, [.dragBegin])
    }

    func testPressedSideLightsOnlyWhileAClickIsStillPossible() {
        let s = sim()
        XCTAssertNil(s.engine.pressedSide)
        s.down(1, 300, 400)
        XCTAssertEqual(s.engine.pressedSide, .right)
        s.up(1, dt: 0.05)
        XCTAssertNil(s.engine.pressedSide)
        s.down(1, 100, 700)
        XCTAssertEqual(s.engine.pressedSide, .left)
        for i in 1...5 { s.move(1, 100 + Double(i) * 4, 700) }
        XCTAssertNil(s.engine.pressedSide, "動かしたらクリックではないので消える")
        s.up(1)
        s.down(1, 100, 400); s.down(2, 140, 400, dt: 0.01)
        XCTAssertNil(s.engine.pressedSide, "2 本指では光らない")
    }

    func testRightEdgeVerticalSlideScrollsWithOneFinger() {
        let s = sim()
        s.down(1, 390, 400)
        for i in 1...10 { s.move(1, 390, 400 + Double(i) * 6) }
        s.up(1)
        let scrolls = s.events.compactMap { e -> (ScrollPhase, Float, Float)? in
            if case let .scroll(p, dx, dy) = e { return (p, dx, dy) } else { return nil }
        }
        XCTAssertEqual(scrolls.first?.0, .began)
        XCTAssertEqual(scrolls.last?.0, .ended)
        XCTAssertFalse(s.events.contains { if case .move = $0 { return true } else { return false } })
        var dy: Float = 0
        for (p, _, y) in scrolls where p != .ended { dy += y }
        XCTAssertEqual(dy, 60, accuracy: 0.01, "動いた量はひとつも失わない")
        XCTAssertTrue(scrolls.allSatisfy { $0.1 == 0 }, "縦だけ。横の動きは混ぜない")
        XCTAssertGreaterThan(scrolls.last!.2, 0, "離す直前の速さが慣性になる")
    }

    func testRightEdgeHorizontalSlideIsCursor() {
        let s = sim()
        s.down(1, 390, 400)
        for i in 1...10 { s.move(1, 390 - Double(i) * 6, 400) }
        s.up(1)
        XCTAssertFalse(s.events.contains { if case .scroll = $0 { return true } else { return false } })
        var x: Float = 0
        for e in s.events { if case let .move(dx, _, _) = e { x += dx } }
        XCTAssertEqual(x, -60, accuracy: 0.01)
    }

    func testEdgeStripBoundaryAndLandscape() {
        let s = sim()
        s.down(1, 369, 400)
        for i in 1...10 { s.move(1, 369, 400 + Double(i) * 6) }
        XCTAssertFalse(s.events.contains { if case .scroll = $0 { return true } else { return false } }, "帯のすぐ外はカーソル")
        let t = Sim()
        t.down(1, 790, 200)
        for i in 1...10 { t.move(1, 790, 200 + Double(i) * 6) }
        XCTAssertFalse(t.events.contains { if case .scroll = $0 { return true } else { return false } }, "横置きに帯は無い")
    }

    func testEdgeScrollEndsWhenASecondFingerLands() {
        let s = sim()
        s.down(1, 390, 400)
        for i in 1...6 { s.move(1, 390, 400 + Double(i) * 6) }
        s.down(2, 200, 400)
        XCTAssertEqual(s.events.last.map { if case .scroll(.ended, _, _) = $0 { return true } else { return false } }, true)
    }

    func testTwoFingerScrollStillWorksInMouseShape() {
        let s = sim()
        s.down(1, 100, 400); s.down(2, 140, 400, dt: 0.01)
        for i in 1...6 { s.move(1, 100, 400 + Double(i) * 5); s.move(2, 140, 400 + Double(i) * 5) }
        XCTAssertTrue(s.events.contains { if case .scroll(.began, _, _) = $0 { return true } else { return false } })
    }

    func testHoldInMouseShapeStillStartsDragWithHeavyThenReleaseHaptic() {
        let s = sim()
        s.down(1, 100, 500)
        s.wait(0.4)
        XCTAssertEqual(s.events, [.dragBegin])
        s.up(1)
        XCTAssertEqual(s.haptics, [.heavy, .release])
    }

    func testTapThenSlideDragWorksInMouseShapeToo() {
        let s = sim()
        s.down(1, 100, 500); s.up(1, dt: 0.05)
        s.down(1, 100, 500, dt: 0.1)
        for i in 1...6 { s.move(1, 100 + Double(i) * 5, 500) }
        XCTAssertEqual(s.events.filter { $0 == .dragBegin }.count, 1)
    }
}
