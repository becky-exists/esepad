import AppKit
import CoreGraphics
import EsepadCore

/// iPhone からの操作を、Mac のカーソル・クリック・スクロールに変える。
/// すべて専用のキューの上で動かし、画面の描画には触らない。
final class PointerController: PadEventSink {
    /// 3 本指のスワイプの出し方
    enum SwipeMode: String {
        /// 左右も上も本物のジェスチャー
        case real
        /// 左右は本物のジェスチャー、上（Mission Control）はキーボードの近道。既定
        case realHorizontalShortcutUp
        /// どちらもキーボードの近道（Control+矢印）
        case shortcut
    }

    struct Settings {
        var speed: Double
        var accelerate: Bool
        var reverseScroll: Bool
        var swipeMode: SwipeMode
    }

    /// 呼ぶたびに今の設定（メニューで変える）を返す
    var settings: () -> Settings = {
        Settings(speed: PointerAcceleration.defaultSpeed, accelerate: true, reverseScroll: false, swipeMode: .realHorizontalShortcutUp)
    }

    private let queue = DispatchQueue(label: "esepad.pointer", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)

    private var smoother = CursorSmoother(alpha: 0.5)
    private var pos = CGPoint.zero
    private var lastMoveTime = 0.0
    private var moveTimer: DispatchSourceTimer?

    private var dragging = false
    /// ドラッグを始めた時のクリック回数（トン→押したまま滑らせると、ダブルクリックのドラッグになる）
    private var dragClicks = 1
    private var swipeDriver: DockSwipeDriver?
    private var clicks = ClickCounter(interval: NSEvent.doubleClickInterval)
    private var rightClicks = ClickCounter(interval: NSEvent.doubleClickInterval)

    private var inertia: ScrollInertia?
    private var inertiaTimer: DispatchSourceTimer?
    private var emitter = ScrollEmitter()
    private var scrollSign = 1.0

    private var displayCache: [CGRect] = []
    private var displayCacheTime = 0.0

    /// 指 1pt が画面で何ピクセル分のスクロールになるか
    private let scrollGain = 1.6

    // MARK: 入口

    func handle(_ e: PadEvent) {
        queue.async { self.handleOnQueue(e) }
    }

    /// つながりが切れた時。押しっぱなし・慣性を片づける。
    func releaseAll() {
        queue.async {
            self.stopInertia(finish: true)
            ScrollPoster.post(self.emitter.cancel())
            self.flushPending()
            if self.swipeDriver != nil { self.finishSwipeSession() }
            if self.dragging {
                self.dragging = false
                self.postMouse(.leftMouseUp, button: .left, clicks: self.dragClicks)
            }
            self.smoother.reset()
            self.stopMoveTimer()
        }
    }

    private func handleOnQueue(_ e: PadEvent) {
        switch e {
        case let .move(dx, dy, dtMs):
            stopInertia(finish: true)
            beginMoveIfIdle()
            let s = settings()
            let accel = PointerAcceleration(speed: s.speed, accelerate: s.accelerate)
            let seconds = Double(max(dtMs, 4)) / 1000
            let velocity = hypot(Double(dx), Double(dy)) / seconds
            let g = accel.gain(velocity: velocity)
            smoother.add(dx: Double(dx) * g, dy: Double(dy) * g)
            startMoveTimer()

        case .click:
            stopInertia(finish: true)
            beginMoveIfIdle()
            flushPending()
            let n = clicks.register(time: CFAbsoluteTimeGetCurrent(), x: pos.x, y: pos.y)
            postMouse(.leftMouseDown, button: .left, clicks: n)
            postMouse(.leftMouseUp, button: .left, clicks: n)

        case .rightClick:
            stopInertia(finish: true)
            beginMoveIfIdle()
            flushPending()
            // 右のトントンは、右のダブルクリックになる
            let n = rightClicks.register(time: CFAbsoluteTimeGetCurrent(), x: pos.x, y: pos.y)
            postMouse(.rightMouseDown, button: .right, clicks: n)
            postMouse(.rightMouseUp, button: .right, clicks: n)

        case .dragBegin:
            stopInertia(finish: true)
            beginMoveIfIdle()
            flushPending()
            guard !dragging else { return }
            dragging = true
            // 直前のトンから続けて押した時は、クリック回数が 2 になる（本物のトラックパッドのドラッグと同じ）
            dragClicks = clicks.register(time: CFAbsoluteTimeGetCurrent(), x: pos.x, y: pos.y)
            postMouse(.leftMouseDown, button: .left, clicks: dragClicks)

        case .dragEnd:
            flushPending()
            guard dragging else { return }
            dragging = false
            postMouse(.leftMouseUp, button: .left, clicks: dragClicks)
            dragClicks = 1

        case let .scroll(phase, dx, dy):
            handleScroll(phase: phase, dx: Double(dx), dy: Double(dy))

        case let .swipe(dir):
            stopInertia(finish: true)
            handleSwipe(dir)

        case let .swipeDrag(phase, dx, dy):
            handleSwipeDrag(phase: phase, dx: Double(dx), dy: Double(dy))

        case .ping:
            break   // 往復時間の確かめは、通信の側で返している
        }
    }

    // MARK: カーソル

    /// しばらく止まっていたら、いまのカーソルの位置から数え直す（ふだんのマウスやトラックパッドと併用できる）
    private func beginMoveIfIdle() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveTime > 0.15, let loc = CGEvent(source: nil)?.location { pos = loc }
        lastMoveTime = now
    }

    private func startMoveTimer() {
        guard moveTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 240 回/秒。動かす分が残っている間だけ回す
        t.schedule(deadline: .now(), repeating: .microseconds(4166), leeway: .microseconds(300))
        t.setEventHandler { [weak self] in self?.moveTick() }
        moveTimer = t
        t.resume()
    }

    private func stopMoveTimer() {
        moveTimer?.cancel()
        moveTimer = nil
    }

    private func moveTick() {
        let d = smoother.step()
        applyMove(dx: d.dx, dy: d.dy)
        if smoother.isIdle { stopMoveTimer() }
    }

    private func flushPending() {
        let d = smoother.drain()
        if d.dx != 0 || d.dy != 0 { applyMove(dx: d.dx, dy: d.dy) }
    }

    private func applyMove(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        lastMoveTime = CFAbsoluteTimeGetCurrent()
        pos = DisplayGeometry.clamp(CGPoint(x: pos.x + dx, y: pos.y + dy), to: displays())
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        ev.post(tap: .cghidEventTap)
    }

    private func displays() -> [CGRect] {
        let now = CFAbsoluteTimeGetCurrent()
        if displayCache.isEmpty || now - displayCacheTime > 1 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var n: UInt32 = 0
            if CGGetActiveDisplayList(16, &ids, &n) == .success, n > 0 {
                displayCache = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
            } else {
                displayCache = [CGDisplayBounds(CGMainDisplayID())]
            }
            displayCacheTime = now
        }
        return displayCache
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton, clicks: Int) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        // Control の印は付けない。Mac では Control つきの左クリックが右クリックになるので、
        // Control が押しっぱなし扱いで残っていると、タップが全部右クリックになる（実機で起きた）。
        // 右クリックは 2 本指のタップで出せるので、Control＋タップは意図的に使えなくしている。
        ev.flags.remove(.maskControl)
        ev.post(tap: .cghidEventTap)
    }

    // MARK: 3 本指のスワイプ（デスクトップ切り替え・Mission Control）

    /// 指についてくる版。始まり→途中→終わりを、DockSwipeDriver が Dock に出す段階に変える。
    /// 段階が出せない（macOS 26 以前・近道に切り替えている）向きは、離した時に 1 回だけ切り替える。
    private func handleSwipeDrag(phase: ScrollPhase, dx: Double, dy: Double) {
        switch phase {
        case .began:
            stopInertia(finish: true)
            if swipeDriver != nil { finishSwipeSession() }
            let mode = settings().swipeMode
            let canStep = DockSwipePoster.needsRawPayload
            swipeDriver = DockSwipeDriver(fluidHorizontal: canStep && mode != .shortcut,
                                          fluidVertical: canStep && mode == .real)
            let out = swipeDriver?.begin(dx: dx, dy: dy) ?? []
            run(out)
        case .changed:
            guard swipeDriver != nil else { return }
            let out = swipeDriver?.changed(dx: dx, dy: dy) ?? []
            run(out)
        case .ended:
            guard swipeDriver != nil else { return }
            let out = swipeDriver?.ended(vx: dx, vy: dy) ?? []
            swipeDriver = nil
            run(out)
        }
    }

    private func run(_ outputs: [DockSwipeDriver.Output]) {
        for o in outputs {
            switch o {
            case let .step(step):
                if !DockSwipePoster.post(step: step) { swipeDriver?.demoteToCommit() }
            case let .commit(dir):
                handleSwipe(dir)
            }
        }
    }

    /// つながりが切れた時・始まり直した時に、Dock の途中のジェスチャーを残さない
    private func finishSwipeSession() {
        let out = swipeDriver?.abort() ?? []
        swipeDriver = nil
        run(out)
    }

    /// スワイプは「内容が動く向き」。左へ払うと、右隣のデスクトップへ。
    /// 本物のジェスチャーが作れなかった時は、キーボードの近道に切り替える。
    private func handleSwipe(_ dir: SwipeDirection) {
        let mode = settings().swipeMode
        switch dir {
        case .left, .right:
            let toRight = dir == .left
            if mode != .shortcut, DockSwipePoster.switchDesktop(toRight: toRight) { return }
            postKey(toRight ? 124 : 123)
        case .up:
            if mode == .real, DockSwipePoster.missionControl() { return }
            postKey(126)
        }
    }

    /// Control + 矢印だけ。ほかのキーは送らない。
    /// 本物のキーボードと同じく「Control を押す → 矢印 → Control を離す」の順で送る。
    /// 矢印に Control の印だけ付けて送ると、Mac が Control を押しっぱなしと思い込み、
    /// そのあとのクリックが右クリックになることがある（実機で起きた）。
    private func postKey(_ code: CGKeyCode) {
        let control: CGKeyCode = 59
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
        post(control, down: true, flags: .maskControl)
        post(code, down: true, flags: [.maskControl, .maskSecondaryFn])
        post(code, down: false, flags: [.maskControl, .maskSecondaryFn])
        post(control, down: false, flags: [])
    }

    // MARK: スクロール

    /// 合成したイベントには「ナチュラルスクロール」の設定がかからないので、向きは自分で決める。
    private func currentScrollSign() -> Double {
        let key = "com.apple.swipescrolldirection" as CFString
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let natural = (CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? Bool) ?? true
        return ScrollDirection.sign(systemNatural: natural, reversed: settings().reverseScroll)
    }

    private func handleScroll(phase: ScrollPhase, dx: Double, dy: Double) {
        switch phase {
        case .began:
            stopInertia(finish: true)
            scrollSign = currentScrollSign()
            ScrollPoster.post(emitter.touchBegan(dx: dx * scrollGain * scrollSign, dy: dy * scrollGain * scrollSign))
        case .changed:
            ScrollPoster.post(emitter.touchChanged(dx: dx * scrollGain * scrollSign, dy: dy * scrollGain * scrollSign))
        case .ended:
            ScrollPoster.post(emitter.touchEnded())
            inertia = ScrollInertia(vx: dx * scrollGain * scrollSign, vy: dy * scrollGain * scrollSign)
            if inertia != nil { startInertiaTimer() }
        }
    }

    private func startInertiaTimer() {
        guard inertiaTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(8), repeating: .microseconds(8333), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.inertiaTick() }
        inertiaTimer = t
        t.resume()
    }

    private func inertiaTick() {
        guard var i = inertia else { stopInertia(finish: false); return }
        let r = i.step(dt: 1.0 / 120)
        inertia = i
        if r.finished {
            stopInertia(finish: true)
            return
        }
        ScrollPoster.post(emitter.momentum(dx: Double(r.dx), dy: Double(r.dy)))
    }

    /// 慣性を止める。始まっていたなら「終わり」を送って、アプリ側の動きも止める。
    private func stopInertia(finish: Bool) {
        inertiaTimer?.cancel()
        inertiaTimer = nil
        inertia = nil
        if finish { ScrollPoster.post(emitter.momentumEnded()) }
    }
}
