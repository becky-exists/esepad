import Foundation

/// スクロールの向き。合成したイベントには「ナチュラルスクロール」の設定がかからないので、自分で反映する。
public enum ScrollDirection {
    /// 指の動き（下へ動かす = 正）に掛ける符号。
    /// ナチュラル（指に内容がついてくる）なら +1、ふつう（ホイール型）なら -1。メニューの「逆にする」で反転。
    public static func sign(systemNatural: Bool, reversed: Bool) -> Double {
        (systemNatural ? 1.0 : -1.0) * (reversed ? -1.0 : 1.0)
    }
}

/// 本物のトラックパッドに近いスクロールを出すための手順（どのイベントを、どの順で出すか）。
/// 画面にも CGEvent にも触らず、手順だけを返す。Mac 側がこれを CGEvent に変える。
///
/// 手順は LinearMouse（MIT）の SmoothedScrollingTransformer を参考にしている（NOTICE を参照）。
public struct ScrollEmitter {
    /// 向き・段階の値（CGScrollPhase / CGMomentumScrollPhase / ジェスチャーの段階）
    public enum Phase {
        public static let began: UInt8 = 1
        public static let changed: UInt8 = 2
        public static let ended: UInt8 = 4
        public static let cancelled: UInt8 = 8
        public static let mayBegin: UInt8 = 128
    }

    public enum Momentum {
        public static let none: UInt8 = 0
        public static let begin: UInt8 = 1
        public static let `continue`: UInt8 = 2
        public static let end: UInt8 = 3
    }

    public enum Op: Equatable {
        /// type 29 のジェスチャーイベント（HID の種類 = scroll）
        case gesture(phase: UInt8, dx: Double, dy: Double)
        /// ジェスチャーの列の始まり／終わり
        case series(started: Bool)
        /// スクロールホイールのイベント（ピクセル）
        case wheel(dx: Double, dy: Double, scrollPhase: UInt8, momentumPhase: UInt8)
    }

    private var remX = 0.0
    private var remY = 0.0
    private var seriesActive = false
    private var momentumActive = false

    public init() {}

    public var isTouching: Bool { seriesActive }
    public var isMomentum: Bool { momentumActive }

    private mutating func whole(_ dx: Double, _ dy: Double) -> (Double, Double) {
        let cx = dx + remX, cy = dy + remY
        let wx = cx.rounded(.towardZero), wy = cy.rounded(.towardZero)
        remX = cx - wx
        remY = cy - wy
        return (wx, wy)
    }

    /// 2 本指が触れた。
    public mutating func touchBegan(dx: Double, dy: Double) -> [Op] {
        var ops: [Op] = []
        remX = 0
        remY = 0
        let (wx, wy) = whole(dx, dy)
        if !seriesActive {
            ops.append(.gesture(phase: Phase.mayBegin, dx: 0, dy: 0))
            ops.append(.series(started: true))
            seriesActive = true
        }
        ops.append(.gesture(phase: Phase.began, dx: wx, dy: wy))
        ops.append(.wheel(dx: wx, dy: wy, scrollPhase: Phase.began, momentumPhase: Momentum.none))
        return ops
    }

    public mutating func touchChanged(dx: Double, dy: Double) -> [Op] {
        guard seriesActive else { return [] }
        let (wx, wy) = whole(dx, dy)
        return [.gesture(phase: Phase.changed, dx: wx, dy: wy),
                .wheel(dx: wx, dy: wy, scrollPhase: Phase.changed, momentumPhase: Momentum.none)]
    }

    /// 指を離した。続けて慣性を出す時は、そのあと momentum を呼ぶ。
    public mutating func touchEnded() -> [Op] {
        guard seriesActive else { return [] }
        seriesActive = false
        remX = 0
        remY = 0
        return [.gesture(phase: Phase.ended, dx: 0, dy: 0),
                .series(started: false),
                .wheel(dx: 0, dy: 0, scrollPhase: Phase.ended, momentumPhase: Momentum.none)]
    }

    /// 慣性の 1 コマ（整数のピクセル）。最初の 1 回は「始まり」、以降は「途中」。
    public mutating func momentum(dx: Double, dy: Double) -> [Op] {
        let phase = momentumActive ? Momentum.continue : Momentum.begin
        momentumActive = true
        return [.wheel(dx: dx, dy: dy, scrollPhase: 0, momentumPhase: phase)]
    }

    /// 慣性が終わった・止められた。始まっていなければ何も出さない。
    public mutating func momentumEnded() -> [Op] {
        guard momentumActive else { return [] }
        momentumActive = false
        return [.wheel(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: Momentum.end)]
    }

    /// つながりが切れた時など。触れている途中なら「取り消し」で閉じる。
    public mutating func cancel() -> [Op] {
        var ops: [Op] = []
        if seriesActive {
            seriesActive = false
            ops += [.gesture(phase: Phase.cancelled, dx: 0, dy: 0),
                    .series(started: false),
                    .wheel(dx: 0, dy: 0, scrollPhase: Phase.cancelled, momentumPhase: Momentum.none)]
        }
        ops += momentumEnded()
        remX = 0
        remY = 0
        return ops
    }
}
