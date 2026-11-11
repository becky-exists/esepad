import Foundation

/// 3 本指のスワイプを、指についてくる動きにするための組み立て役。
/// iPhone から来る「始まり・動き・終わり」を受けて、Mac が Dock に出す段階つきのジェスチャーの値に変える。
/// 画面にも CGEvent にも依存しないので、テストでそのまま回せる。
///
/// 進み具合（progress）は「デスクトップ 1 枚ぶん = 1.0」。右のデスクトップへ進む向きがマイナス、
/// Mission Control（上）がプラス（上向きの符号は実機で確かめていない）。
/// 切り替わる／戻るは、離した時の位置と速さでここで決める（決めた結果を、終わりの段階の速さで OS に伝える）。
public struct DockSwipeDriver {
    public enum Axis: Equatable { case horizontal, vertical }

    /// Dock に出す 1 段階ぶん
    public struct Step: Equatable {
        public var phase: Int       // 1 始まり / 2 途中 / 4 終わり
        public var motion: Int      // 1 横 / 2 縦
        public var progress: Double
        public var velX: Double
        public var velY: Double
    }

    public enum Output: Equatable {
        case step(Step)
        /// 段階つきで出さない向き（キーボードの近道など）で、切り替えると決まった時に 1 回だけ出る
        case commit(SwipeDirection)
    }

    /// 指が何 pt 動くと progress が 1.0 になるか。小さいほど、少ない動きでデスクトップが動く
    public static let fullTravel = 360.0
    /// 段階つきで出す時、これ以上進めて離したら切り替える
    public static let fluidCommit = 0.5
    /// 段階を出さない向き（近道）の時、これ以上動かして離したら切り替える（70pt 相当）
    public static let shortcutCommit = 0.2
    /// これ以上の速さ（デスクトップ 1 枚ぶん/秒）で払って離したら、距離が足りなくても切り替える
    public static let flickSpeed = 1.5
    /// 払いの速さだけで切り替えるのに最低限必要な進み
    public static let flickMinProgress = 0.1
    /// 切り替えると決めた時に OS へ伝える速さ（一瞬で動かしていた時と同じ値）
    static let commitVelocity = 9999.0

    public let fluidHorizontal: Bool
    public let fluidVertical: Bool
    public private(set) var axis: Axis?
    /// 段階を出していて、まだ終わりを出していない
    public private(set) var fluidOpen = false
    private var travel = 0.0

    public init(fluidHorizontal: Bool, fluidVertical: Bool) {
        self.fluidHorizontal = fluidHorizontal
        self.fluidVertical = fluidVertical
    }

    public var progress: Double {
        switch axis {
        case .horizontal?: return max(-1, min(1, travel))
        case .vertical?: return max(0, min(1, travel))
        case nil: return 0
        }
    }

    private func signed(dx: Double, dy: Double) -> Double {
        axis == .vertical ? -dy / Self.fullTravel : dx / Self.fullTravel
    }

    private var fluid: Bool { axis == .horizontal ? fluidHorizontal : fluidVertical }

    private var motion: Int { axis == .vertical ? 2 : 1 }

    public mutating func begin(dx: Double, dy: Double) -> [Output] {
        axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        travel = signed(dx: dx, dy: dy)
        guard fluid else { return [] }
        fluidOpen = true
        return [.step(Step(phase: 1, motion: motion, progress: 0, velX: 0, velY: 0)),
                .step(Step(phase: 2, motion: motion, progress: progress, velX: 0, velY: 0))]
    }

    public mutating func changed(dx: Double, dy: Double) -> [Output] {
        guard axis != nil else { return [] }
        // 上限（行き止まり）を越えて溜め込まない。戻す動きがすぐ効くように
        travel = axis == .vertical ? max(0, min(1, travel + signed(dx: dx, dy: dy)))
                                   : max(-1, min(1, travel + signed(dx: dx, dy: dy)))
        guard fluidOpen else { return [] }
        return [.step(Step(phase: 2, motion: motion, progress: progress, velX: 0, velY: 0))]
    }

    /// 指が離れた。vx, vy は離す直前の速さ（pt/秒）
    public mutating func ended(vx: Double, vy: Double) -> [Output] {
        guard let axis = axis else { return [] }
        defer { self.axis = nil; fluidOpen = false; travel = 0 }
        let p = progress
        let v = axis == .vertical ? -vy / Self.fullTravel : vx / Self.fullTravel
        // 払った向きが、進んでいる向きと同じなら勢いで切り替える
        let flick = abs(v) >= Self.flickSpeed && abs(p) >= Self.flickMinProgress && (v > 0) == (p > 0)
        let commit = abs(p) >= (fluidOpen ? Self.fluidCommit : Self.shortcutCommit) || flick
        let sign = p < 0 ? -1.0 : 1.0
        if fluidOpen {
            let vel = commit ? sign * Self.commitVelocity : 0
            return [.step(Step(phase: 4, motion: motion, progress: p,
                               velX: axis == .horizontal ? vel : 0, velY: axis == .vertical ? vel : 0))]
        }
        guard commit else { return [] }
        switch axis {
        case .horizontal: return [.commit(p < 0 ? .left : .right)]
        case .vertical: return [.commit(.up)]
        }
    }

    /// つながりが切れた・段階を出せなかった時。出している途中なら、戻す形で終わらせる
    public mutating func abort() -> [Output] {
        guard axis != nil, fluidOpen else { axis = nil; return [] }
        let step = Step(phase: 4, motion: motion, progress: progress, velX: 0, velY: 0)
        axis = nil
        fluidOpen = false
        travel = 0
        return [.step(step)]
    }

    /// 段階を出せなかった（OS が受け付けない）時。以降は、終わりに 1 回だけ切り替える形にする
    public mutating func demoteToCommit() { fluidOpen = false }
}
