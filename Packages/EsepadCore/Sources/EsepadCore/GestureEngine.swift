import Foundation

public struct TouchPoint: Equatable {
    public var id: Int
    public var x: Double
    public var y: Double
    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

public enum Haptic: Equatable {
    case light, medium, soft
    /// ドラッグに入った時（長押し・トン→押したまま）。いちばん強い震えを、短く 2 回
    case heavy
    /// ドラッグを離した時。軽い
    case release
}

/// 縦に置いた時の「マウスの形」で、画面のどちら側か
public enum PadSide: Equatable {
    case left, right
}

/// 縦に置いた時（マウスの形）の面の決まり。横置き（トラックパッド）では使わない。
/// - 面ぜんぶを縦のまん中で左右に分ける。左半分のトン＝左クリック、右半分のトン＝右クリック（置いたマウスの左右のボタン）。
///   なぞりは、どちら側でも面ぜんぶでカーソルになる
/// - 右端の `edgeWidth` の幅の帯で始めて縦になぞると、スクロール
public struct MouseLayout: Equatable {
    public static let defaultEdgeWidth = 30.0

    public var width: Double
    public var height: Double
    public var edgeWidth = MouseLayout.defaultEdgeWidth

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    func side(atX x: Double) -> PadSide? {
        guard width > 0 else { return nil }
        return x < width / 2 ? .left : .right
    }

    func isEdge(x: Double) -> Bool { width > 0 && x >= width - edgeWidth }
}

public enum GestureAction: Equatable {
    case event(PadEvent)
    case haptic(Haptic)
}

public struct GestureConfig: Equatable {
    /// これ以上動いたら「タップ」ではなく「移動」（pt）
    public var moveSlop = 4.0
    /// 指を置いてから離すまでがこれ以内ならタップ（秒）
    public var tapMaxDuration = 0.28
    /// 2 本目・3 本目の指が「同時に置いた」とみなす時間（秒）
    public var settleWindow = 0.12
    /// 動かさずに置き続けたらドラッグの開始（秒）
    public var holdDuration = 0.35
    /// 「トン→すぐ置いて押したまま滑らせる」でドラッグに入れる、1 回目のトンのあとの時間（秒）
    public var dragTapWindow = 0.30
    /// 同じく、1 回目のトンの場所からの近さ（pt）。離れていたら、ただの「クリックのあとの移動」
    public var dragTapRadius = 80.0
    /// 2 本指でこれ以上動いたらスクロール（pt）
    public var scrollSlop = 3.0
    /// 3 本指でこれ以上動いたらスワイプを始める（pt）。始まったあとは指についていく
    public var swipeLockDistance = 12.0
    /// スワイプで、主な向きが逆向きの 1.5 倍以上であること
    public var swipeDominance = 1.5

    public init() {}
}

/// 指の速さを見積もる。指を離す直前の速さを、慣性スクロールの勢いにする。
public struct VelocityTracker {
    private var samples: [(t: Double, x: Double, y: Double)] = []

    public init() {}

    public mutating func reset() { samples.removeAll() }

    public mutating func add(t: Double, x: Double, y: Double) {
        samples.append((t, x, y))
        samples.removeAll { t - $0.t > 0.2 }
    }

    /// 直近 0.1 秒の速さ（pt/秒）。離す直前に止まっていたら 0。
    public func velocity(at now: Double) -> (vx: Double, vy: Double) {
        let recent = samples.filter { now - $0.t <= 0.1 }
        guard recent.count >= 2, let first = recent.first, let last = recent.last, now - last.t <= 0.06 else { return (0, 0) }
        let dt = last.t - first.t
        guard dt > 0.005 else { return (0, 0) }
        return ((last.x - first.x) / dt, (last.y - first.y) / dt)
    }
}

/// 指の判定の差し込み口。iPhone 側はこの形だけを見るので、中身を別の実装に入れ替えられる。
public protocol GestureRecognizing: AnyObject {
    func update(time: Double, touches: [TouchPoint]) -> [GestureAction]
    func tick(time: Double) -> [GestureAction]
}

/// 指の数と動きから「何をしたか」を決める。UIKit に依存しないので、テストでそのまま回せる。
///
/// 使い方: 指が増えた・動いた・離れたたびに、いま触れている指をすべて `update` へ渡す。
/// 「置き続けているかどうか」の判定のために、一定間隔で `tick` も呼ぶ。
public final class GestureEngine: GestureRecognizing {
    private enum Mode {
        case idle
        /// まだ何をするか決まっていない
        case pending
        case cursor
        case drag
        case scroll
        /// 3 本指のスワイプが始まった。指が 3 本の間は動きを送り、減ったら終わりにする
        case swiping
        /// 4 本指など、扱わない。全部離すまで何もしない
        case dead
    }

    public var config: GestureConfig

    private var mode: Mode = .idle
    private var startTime = 0.0
    private var lastTime = 0.0
    private var startC = (x: 0.0, y: 0.0)
    private var lastC = (x: 0.0, y: 0.0)
    private var maxN = 0
    private var settledN = 0
    private var currentN = 0
    private var primaryID: Int?
    private var velocity = VelocityTracker()
    private var lastNow = 0.0
    /// 1 回目のトン（左クリック）の時刻と場所
    private var lastTap: (t: Double, x: Double, y: Double)?
    /// この指は、トンの直後に置かれた（滑らせたらすぐドラッグ）
    private var afterTap = false
    /// この指は右端の帯で置かれた（縦に滑らせたらスクロール）
    private var edgeCandidate = false
    /// 1 本指のスクロール（右端の帯）
    private var edgeScroll = false

    /// 縦置き（マウスの形）の時だけ設定する。nil なら横置きのトラックパッド
    public var mouseLayout: MouseLayout?

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    public var isIdle: Bool { mode == .idle }

    /// いま、左右どちらの側を指が押さえているか（縦置きで、まだクリックになれる間だけ）。画面を一瞬光らせるため
    public var pressedSide: PadSide? {
        guard mode == .pending, currentN == 1, maxN == 1, lastNow - startTime <= config.tapMaxDuration else { return nil }
        return mouseLayout?.side(atX: startC.x)
    }

    private func centroid(_ t: [TouchPoint]) -> (x: Double, y: Double) {
        let n = Double(t.count)
        return (t.reduce(0) { $0 + $1.x } / n, t.reduce(0) { $0 + $1.y } / n)
    }

    private func reset() {
        mode = .idle
        maxN = 0
        settledN = 0
        currentN = 0
        primaryID = nil
        velocity.reset()
        afterTap = false
        edgeCandidate = false
        edgeScroll = false
    }

    /// 後から指が増えた（同時に置いたのではない）
    private var late: Bool { maxN != settledN }

    public func update(time: Double, touches: [TouchPoint]) -> [GestureAction] {
        let n = touches.count
        currentN = n
        lastNow = time
        if n == 0 { return finish(time: time) }
        let c = centroid(touches)
        var out: [GestureAction] = []

        switch mode {
        case .idle:
            mode = .pending
            startTime = time
            lastTime = time
            startC = c
            lastC = c
            maxN = n
            settledN = n
            primaryID = touches[0].id
            if n == 1 {
                if let t = lastTap, time - t.t <= config.dragTapWindow, hypot(c.x - t.x, c.y - t.y) <= config.dragTapRadius {
                    afterTap = true
                }
                edgeCandidate = mouseLayout?.isEdge(x: c.x) ?? false
            }
            lastTap = nil
            if n >= 4 { mode = .dead }

        case .pending:
            if n >= 4 { mode = .dead; break }
            if n > maxN {
                // 指が増えると重心が飛ぶので、基準を取り直す。同時に置いたなら、その本数で判定する
                if time - startTime <= config.settleWindow { settledN = n }
                afterTap = false
                edgeCandidate = false
                maxN = n
                startC = c
                lastC = c
                lastTime = time
                break
            }
            // 何本か置いたあと一部が離れて残った指では、動かさない（離す途中の動きを拾わない）
            if n < maxN { lastC = c; lastTime = time; break }
            let disp = hypot(c.x - startC.x, c.y - startC.y)
            switch n {
            case 1 where disp > config.moveSlop:
                primaryID = touches[0].id
                let dx = c.x - startC.x, dy = c.y - startC.y
                if edgeCandidate, abs(dy) >= abs(dx) {
                    // 右端の帯で始めて縦になぞった。スクロール（横に動いたらカーソル）
                    mode = .scroll
                    edgeScroll = true
                    velocity.reset()
                    velocity.add(t: time, x: 0, y: c.y)
                    out.append(.event(.scroll(phase: .began, dx: 0, dy: Float(dy))))
                } else if afterTap {
                    // トンのあと、離さずに置いて滑らせた。待たずにドラッグ
                    mode = .drag
                    out.append(.event(.dragBegin))
                    out.append(.haptic(.heavy))
                    out.append(.event(.move(dx: Float(dx), dy: Float(dy), dtMs: frameMs(time))))
                } else {
                    mode = .cursor
                    out.append(.event(.move(dx: Float(dx), dy: Float(dy), dtMs: frameMs(time))))
                }
                lastC = c
                lastTime = time
            case 2 where disp > config.scrollSlop:
                mode = .scroll
                velocity.reset()
                velocity.add(t: time, x: c.x, y: c.y)
                out.append(.event(.scroll(phase: .began, dx: Float(c.x - startC.x), dy: Float(c.y - startC.y))))
                lastC = c
                lastTime = time
            case 3:
                if swipe(from: startC, to: c) != nil {
                    mode = .swiping
                    velocity.reset()
                    velocity.add(t: time, x: c.x, y: c.y)
                    out.append(.event(.swipeDrag(phase: .began, dx: Float(c.x - startC.x), dy: Float(c.y - startC.y))))
                    out.append(.haptic(.soft))
                    lastC = c
                    lastTime = time
                }
            default: break
            }

        case .cursor:
            if n == 1 {
                if touches[0].id != primaryID {
                    // 指が入れ替わった。飛ばないように基準だけ取り直す
                    primaryID = touches[0].id
                } else {
                    out.append(.event(.move(dx: Float(c.x - lastC.x), dy: Float(c.y - lastC.y), dtMs: frameMs(time))))
                }
                lastC = c
                lastTime = time
            } else if n == 2 {
                beginScroll(at: c, time: time)
                out.append(.event(.scroll(phase: .began, dx: 0, dy: 0)))
            } else {
                mode = .dead
            }

        case .drag:
            if let p = touches.first(where: { $0.id == primaryID }) {
                out.append(.event(.move(dx: Float(p.x - lastC.x), dy: Float(p.y - lastC.y), dtMs: frameMs(time))))
                lastC = (p.x, p.y)
                lastTime = time
            } else {
                // 動かしていた指が離れた。残りの指ではドラッグしない
                out.append(.event(.dragEnd))
                out.append(.haptic(.release))
                mode = .dead
            }

        case .scroll:
            if n == (edgeScroll ? 1 : 2) {
                let dx = edgeScroll ? 0 : c.x - lastC.x
                out.append(.event(.scroll(phase: .changed, dx: Float(dx), dy: Float(c.y - lastC.y))))
                velocity.add(t: time, x: edgeScroll ? 0 : c.x, y: c.y)
                lastC = c
                lastTime = time
            } else {
                out.append(scrollEnd(time: time))
                mode = .dead
            }

        case .swiping:
            if n == 3 {
                out.append(.event(.swipeDrag(phase: .changed, dx: Float(c.x - lastC.x), dy: Float(c.y - lastC.y))))
                velocity.add(t: time, x: c.x, y: c.y)
                lastC = c
                lastTime = time
            } else {
                // 指が 3 本でなくなった（離れた）。離す直前の速さで終わりにする
                out.append(swipeEnd(time: time))
                mode = .dead
            }

        case .dead:
            break
        }
        return out
    }

    /// 置き続けているかを見るために、一定間隔で呼ぶ。
    public func tick(time: Double) -> [GestureAction] {
        lastNow = max(lastNow, time)
        guard mode == .pending, currentN == 1, maxN == 1,
              time - startTime >= config.holdDuration else { return [] }
        mode = .drag
        lastTime = time
        return [.event(.dragBegin), .haptic(.heavy)]
    }

    // MARK: 内部

    private func frameMs(_ time: Double) -> Float {
        Float(max(4, min(100, (time - lastTime) * 1000)))
    }

    private func beginScroll(at c: (x: Double, y: Double), time: Double) {
        mode = .scroll
        velocity.reset()
        velocity.add(t: time, x: c.x, y: c.y)
        lastC = c
        lastTime = time
    }

    private func scrollEnd(time: Double) -> GestureAction {
        let v = velocity.velocity(at: time)
        return .event(.scroll(phase: .ended, dx: Float(v.vx), dy: Float(v.vy)))
    }

    private func swipeEnd(time: Double) -> GestureAction {
        let v = velocity.velocity(at: time)
        return .event(.swipeDrag(phase: .ended, dx: Float(v.vx), dy: Float(v.vy)))
    }

    private func swipe(from a: (x: Double, y: Double), to b: (x: Double, y: Double)) -> SwipeDirection? {
        let dx = b.x - a.x, dy = b.y - a.y
        if abs(dx) >= config.swipeLockDistance, abs(dx) >= abs(dy) * config.swipeDominance {
            return dx < 0 ? .left : .right
        }
        // 上は画面の上向き（y が小さくなる向き）。下向きは使わない
        if -dy >= config.swipeLockDistance, abs(dy) >= abs(dx) * config.swipeDominance { return .up }
        return nil
    }

    private func finish(time: Double) -> [GestureAction] {
        var out: [GestureAction] = []
        switch mode {
        case .pending:
            if time - startTime <= config.tapMaxDuration, !late {
                switch maxN {
                case 1:
                    switch mouseLayout?.side(atX: startC.x) {
                    case .right?:
                        // 右半分のトン＝右クリック（左ボタンのトンではないので、続けて滑らせてもドラッグにはならない）
                        out = [.event(.rightClick), .haptic(.medium)]
                    case .left?, nil:
                        out = [.event(.click), .haptic(.light)]
                        lastTap = (time, startC.x, startC.y)
                    }
                case 2: out = [.event(.rightClick), .haptic(.medium)]
                default: break
                }
            }
        case .drag:
            out = [.event(.dragEnd), .haptic(.release)]
        case .scroll:
            out = [scrollEnd(time: time)]
        case .swiping:
            out = [swipeEnd(time: time)]
        default:
            break
        }
        reset()
        return out
    }
}
