import CoreGraphics
import Foundation
import EsepadCore

/// 本物のトラックパッドが出すのと同じ形のスクロールのイベントを出す。
/// 手順（どのイベントをどの順で出すか）は EsepadCore の ScrollEmitter が決め、ここで CGEvent に変える。
/// イベントの形は LinearMouse（MIT）を参考にしている（NOTICE を参照）。
enum ScrollPoster {
    // 非公開のフィールド番号（WebKit のテスト用ヘッダーに載っているもの）
    private static let gestureHIDType = CGEventField(rawValue: 110)!
    private static let gestureSeriesType = CGEventField(rawValue: 117)!
    private static let gestureScrollX = CGEventField(rawValue: 118)!
    private static let gestureScrollY = CGEventField(rawValue: 119)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let scrollGestureFlagBits = CGEventField(rawValue: 135)!

    private static let gestureEventType = CGEventType(rawValue: 29)!
    private static let hidTypeScroll: Int64 = 6
    private static let hidTypeGestureStarted: Int64 = 61
    private static let hidTypeGestureEnded: Int64 = 62
    /// 1 行ぶんのピクセル数（行単位のスクロール量に直す時の目安）
    private static let lineStep = 12.0

    static func post(_ ops: [ScrollEmitter.Op]) {
        for op in ops {
            switch op {
            case let .gesture(phase, dx, dy): postGesture(phase: phase, dx: dx, dy: dy)
            case let .series(started): postSeries(started: started)
            case let .wheel(dx, dy, scrollPhase, momentumPhase):
                postWheel(dx: dx, dy: dy, scrollPhase: scrollPhase, momentumPhase: momentumPhase)
            }
        }
    }

    private static func postGesture(phase: UInt8, dx: Double, dy: Double) {
        guard let ev = CGEvent(source: nil) else { return }
        ev.type = gestureEventType
        ev.setIntegerValueField(gestureHIDType, value: hidTypeScroll)
        ev.setIntegerValueField(gesturePhase, value: Int64(phase))
        ev.setIntegerValueField(scrollGestureFlagBits, value: 1)
        ev.setDoubleValueField(gestureScrollX, value: dx)
        ev.setDoubleValueField(gestureScrollY, value: dy)
        ev.post(tap: .cgSessionEventTap)
    }

    private static func postSeries(started: Bool) {
        guard let ev = CGEvent(source: nil) else { return }
        ev.type = gestureEventType
        ev.setIntegerValueField(gestureHIDType, value: started ? hidTypeGestureStarted : hidTypeGestureEnded)
        ev.setIntegerValueField(gestureSeriesType, value: hidTypeScroll)
        ev.post(tap: .cgSessionEventTap)
    }

    private static func postWheel(dx: Double, dy: Double, scrollPhase: UInt8, momentumPhase: UInt8) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((dy / lineStep).rounded(.towardZero)))
        ev.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((dx / lineStep).rounded(.towardZero)))
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase))
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase))
        // Control つきのスクロールは画面の拡大になることがあるので、印を外す（クリックと同じ理由）
        ev.flags.remove(.maskControl)
        ev.post(tap: .cgSessionEventTap)
    }
}

/// 3 本指のスワイプ（デスクトップ切り替え・Mission Control）を、本物のジェスチャーとして出す。
/// 非公開の仕組みで、将来の macOS で変わると効かなくなる。効かない時は「キーボードの近道」に切り替える。
/// macOS 27 以降の組み立ては joshuarli/iss（0BSD）を土台にしている（NOTICE を参照）。
enum DockSwipePoster {
    private static let eventTypeField = CGEventField(rawValue: 55)!
    private static let hidTypeField = CGEventField(rawValue: 110)!
    private static let swipeMotion = CGEventField(rawValue: 123)!
    private static let swipeProgress = CGEventField(rawValue: 124)!
    private static let swipePositionX = CGEventField(rawValue: 125)!
    private static let velocityX = CGEventField(rawValue: 129)!
    private static let velocityY = CGEventField(rawValue: 130)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let phaseAlias = CGEventField(rawValue: 134)!
    private static let scrollFlagBits = CGEventField(rawValue: 135)!
    private static let zoomDeltaY = CGEventField(rawValue: 138)!
    private static let zoomDeltaX = CGEventField(rawValue: 139)!
    private static let sourceProcessAlias = CGEventField(rawValue: 169)!
    private static let scrollY = CGEventField(rawValue: 119)!

    private static let typeGesture: Int64 = 29
    private static let typeDockControl: Int64 = 30
    private static let hidTypeDockSwipe: Int64 = 23

    static var needsRawPayload: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    /// 隣のデスクトップへ。成功したら true。作れなかった時は false（呼び出し側が近道に切り替える）
    static func switchDesktop(toRight: Bool) -> Bool {
        if needsRawPayload {
            return postAugmented(DockSwipe.horizontalPhases(toRight: toRight, timestamp: mach_absolute_time()))
        }
        return postLegacyHorizontal(toRight: toRight)
    }

    /// 指についてくる動き用に、段階を 1 つ出す（macOS 27 以降のみ）。出せなかったら false
    static func post(step: DockSwipeDriver.Step) -> Bool {
        guard needsRawPayload else { return false }
        let p = DockSwipe.Params(phase: step.phase, motion: step.motion, progress: step.progress, posX: 0.1,
                                 velX: step.velX, velY: step.velY, timestamp: mach_absolute_time())
        guard let ev = makeAugmented(p) else { return false }
        postPair(ev)
        return true
    }

    /// Mission Control。向きの符号は確かめていない。macOS 27 より前では使わない（false を返す）
    static func missionControl() -> Bool {
        guard needsRawPayload else { return false }
        return postAugmented(DockSwipe.verticalPhases(up: true, timestamp: mach_absolute_time()))
    }

    // MARK: macOS 27 以降

    private static func postAugmented(_ phases: [DockSwipe.Params]) -> Bool {
        var events: [CGEvent] = []
        for p in phases {
            guard let ev = makeAugmented(p) else { return false }
            events.append(ev)
        }
        for ev in events { postPair(ev) }
        return true
    }

    private static func makeAugmented(_ p: DockSwipe.Params) -> CGEvent? {
        guard let ev = CGEvent(source: nil) else { return nil }
        ev.setIntegerValueField(eventTypeField, value: typeDockControl)
        ev.setIntegerValueField(hidTypeField, value: hidTypeDockSwipe)
        ev.setIntegerValueField(gesturePhase, value: Int64(p.phase))
        ev.setDoubleValueField(swipeProgress, value: p.progress)
        ev.setIntegerValueField(swipeMotion, value: Int64(p.motion))
        ev.setIntegerValueField(phaseAlias, value: Int64(p.phase))
        ev.setDoubleValueField(zoomDeltaY, value: 3.0)
        ev.setDoubleValueField(sourceProcessAlias, value: Double(mach_absolute_time()))
        ev.setDoubleValueField(swipePositionX, value: p.posX)
        if p.velX != 0 { ev.setDoubleValueField(velocityX, value: p.velX) }
        if p.velY != 0 { ev.setDoubleValueField(velocityY, value: p.velY) }

        guard let data = ev.data as Data?,
              let appended = DockSwipe.appendRawField(to: [UInt8](data), payload: DockSwipe.ioHIDPayload(p)) else { return nil }
        return CGEvent(withDataAllocator: nil, data: Data(appended) as CFData)
    }

    // MARK: macOS 26 以前（横のみ）

    private static func postLegacyHorizontal(toRight: Bool) -> Bool {
        let tiny = Float.leastNonzeroMagnitude
        let flagBits = Int64(Int32(bitPattern: (toRight ? tiny : -tiny).bitPattern))
        var events: [CGEvent] = []
        for phase in [1, 2, 4] {
            guard let ev = CGEvent(source: nil) else { return false }
            ev.setIntegerValueField(eventTypeField, value: typeDockControl)
            ev.setIntegerValueField(hidTypeField, value: hidTypeDockSwipe)
            ev.setIntegerValueField(gesturePhase, value: Int64(phase))
            ev.setIntegerValueField(scrollFlagBits, value: flagBits)
            ev.setIntegerValueField(swipeMotion, value: 1)
            ev.setDoubleValueField(scrollY, value: 0)
            ev.setDoubleValueField(zoomDeltaX, value: Double(tiny))
            if phase == 4 {
                ev.setDoubleValueField(velocityX, value: toRight ? 400 : -400)
                ev.setDoubleValueField(velocityY, value: 0)
            }
            events.append(ev)
        }
        for ev in events { postPair(ev) }
        return true
    }

    /// Dock の操作は、ジェスチャーのイベントとペアで送る
    private static func postPair(_ dock: CGEvent) {
        dock.post(tap: .cgSessionEventTap)
        if let companion = CGEvent(source: nil) {
            companion.setIntegerValueField(eventTypeField, value: typeGesture)
            companion.post(tap: .cgSessionEventTap)
        }
    }
}
