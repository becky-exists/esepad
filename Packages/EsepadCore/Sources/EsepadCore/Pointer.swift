import Foundation
import CoreGraphics

/// カーソルの速さの計算。Mac の「軌跡の速さ」は通さず、ここで自分で決める。
public struct PointerAcceleration: Equatable {
    /// 速さのつまみ（0...1）。
    public var speed: Double
    public var accelerate: Bool

    public init(speed: Double, accelerate: Bool) {
        self.speed = speed
        self.accelerate = accelerate
    }

    public static let defaultSpeed = 0.55

    /// 1 pt の指の動きが何ピクセルになるか（加速を除く）。つまみの端で 0.8 〜 8 倍。
    /// Mac の設定の最大でもだいたい 3 倍前後なので、その上まで出る。
    public var baseGain: Double {
        0.8 * pow(10, min(1, max(0, speed)))
    }

    /// 指の速さ（pt/秒）に応じた倍率を掛けた、最終的な倍率。
    /// ゆっくりなら 0.6 倍で細かく、速く払うと 2.4 倍で遠くまで飛ぶ。
    public func gain(velocity: Double) -> Double {
        guard accelerate else { return baseGain }
        let slow = 80.0, fast = 1200.0
        let t = min(1, max(0, (velocity - slow) / (fast - slow)))
        return baseGain * (0.6 + 1.8 * pow(t, 1.2))
    }
}

/// 届いた移動を 1 回で動かさず、細かく分けて動かす。Bluetooth は数ミリ秒ぶんがまとめて届くので、
/// そのまま動かすとカクつく。
public struct CursorSmoother {
    private var px = 0.0
    private var py = 0.0
    /// 1 回の更新で残りの何割を動かすか
    public var alpha: Double

    public init(alpha: Double = 0.5) { self.alpha = alpha }

    public var isIdle: Bool { px == 0 && py == 0 }

    public mutating func add(dx: Double, dy: Double) {
        px += dx
        py += dy
    }

    public mutating func reset() { px = 0; py = 0 }

    /// 残りを全部いま動かす（クリックの直前に、カーソルを指の位置まで追いつかせる）。
    public mutating func drain() -> (dx: Double, dy: Double) {
        defer { px = 0; py = 0 }
        return (px, py)
    }

    /// 今回動かす量。残りが 1 ピクセル未満なら全部。
    public mutating func step() -> (dx: Double, dy: Double) {
        if hypot(px, py) < 1 {
            defer { px = 0; py = 0 }
            return (px, py)
        }
        let dx = px * alpha, dy = py * alpha
        px -= dx
        py -= dy
        return (dx, dy)
    }
}

/// 連続クリックの数え方（ダブルクリック・トリプルクリック）。
public struct ClickCounter {
    private var lastTime = -100.0
    private var lastX = 0.0
    private var lastY = 0.0
    private var count = 0
    public var interval: Double

    public init(interval: Double = 0.5) { self.interval = interval }

    public mutating func register(time: Double, x: Double, y: Double) -> Int {
        if time - lastTime < interval, hypot(x - lastX, y - lastY) < 6 {
            count = min(count + 1, 3)
        } else {
            count = 1
        }
        lastTime = time
        lastX = x
        lastY = y
        return count
    }
}

/// 指を離したあとに、だんだん遅くなりながら続くスクロール。
public struct ScrollInertia {
    private var vx: Double
    private var vy: Double
    private var carryX = 0.0
    private var carryY = 0.0
    /// 勢いが 1/e になるまでの時間（秒）
    static let tau = 0.32
    static let minStart = 150.0
    static let stopBelow = 25.0

    /// 勢いが足りなければ nil（慣性なし）。
    public init?(vx: Double, vy: Double) {
        guard hypot(vx, vy) >= Self.minStart else { return nil }
        self.vx = vx
        self.vy = vy
    }

    /// dt 秒ぶん進める。動かす量はピクセル（整数）で返し、端数は次に持ち越す。
    public mutating func step(dt: Double) -> (dx: Int, dy: Int, finished: Bool) {
        let decay = exp(-dt / Self.tau)
        let k = Self.tau * (1 - decay)
        carryX += vx * k
        carryY += vy * k
        vx *= decay
        vy *= decay
        let ix = Int(carryX.rounded(.towardZero)), iy = Int(carryY.rounded(.towardZero))
        carryX -= Double(ix)
        carryY -= Double(iy)
        return (ix, iy, hypot(vx, vy) < Self.stopBelow)
    }
}

public enum DisplayGeometry {
    /// 点がどの画面にも入っていなければ、いちばん近い画面の中へ寄せる（画面の隙間で迷子にならない）。
    public static func clamp(_ p: CGPoint, to rects: [CGRect]) -> CGPoint {
        guard !rects.isEmpty else { return p }
        if rects.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDist = Double.greatestFiniteMagnitude
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestDist { bestDist = d; best = q }
        }
        return best
    }
}
