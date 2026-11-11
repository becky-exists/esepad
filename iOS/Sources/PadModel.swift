import Combine
import QuartzCore
import SwiftUI
import UIKit
import EsepadCore

/// iPhone 側の全体の流れ。Bluetooth・頭脳・指の判定・震えをつなぐ。
final class PadModel: ObservableObject {
    enum Screen: Equatable {
        case bluetoothOff
        case searching
        case pickMac
        case connecting(String)
        case pairingWait
        case enterCode
        case ready
        case notPairing
        case unknownMac
        case busy
        case codeMismatch
        case failed
        case saveFailed
    }

    @Published private(set) var screen: Screen = .searching
    @Published private(set) var found: [BluetoothClient.FoundMac] = []
    @Published private(set) var codeMessage: String?
    /// 縦に置いている間は「マウスの形」（向きそのものが切り替え。設定は無い）
    @Published private(set) var mouseMode = false
    /// いま押さえている、縦置きで、いま押さえている側（トンした側を一瞬だけ薄く光らせるため）
    @Published private(set) var pressedSide: PadSide?
    /// 面の色（隣に置く Mac と同じ色にする）。つないだ Mac ごとに覚える
    @Published private(set) var surface: SurfaceColor = .fallback

    // 確かめ用の表示（4 本指で 0.8 秒押さえ続けると開く）
    @Published var showDiagnostics = false
    @Published private(set) var rttSamples: [Double] = []
    @Published private(set) var preferL2CAP = UserDefaults.standard.bool(forKey: "useL2CAP")
    @Published private(set) var transportName = "GATT"
    @Published private(set) var l2capNote: String?

    private let client = BluetoothClient()
    private let keychain = PhoneKeychain()
    private var phoneState: PhoneState
    private var brain: PhoneBrain

    private let engine = GestureEngine()
    private var queue = OutboundQueue()
    private var rawOut: [Data] = []
    private var pairingIntent = false
    private var link: CADisplayLink?
    private var stuckWork: DispatchWorkItem?
    private var diagnosticsWork: DispatchWorkItem?
    private var pingTimer: Timer?
    private var pingSent: [UInt32: Double] = [:]
    private var nextToken: UInt32 = 1
    private var saveFailed = false

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)

    private static let bookKey = "surfaceColorBook"
    private var colorBook = SurfaceColorBook()
    /// Mac が決まる前（つなぐ Mac を選ぶ画面）で選んだ色。Mac を選んだら、その Mac の色にする
    private var colorChosenBeforeMac: SurfaceColor?

    init() {
        let state = keychain.load()
        phoneState = state
        brain = PhoneBrain(deviceID: Hex.decode(state.deviceID) ?? [], record: state.record)
        if let d = UserDefaults.standard.data(forKey: Self.bookKey),
           let b = try? JSONDecoder().decode(SurfaceColorBook.self, from: d) {
            colorBook = b
        }
        surface = colorBook.color(for: state.macID)

        client.onPower = { [weak self] on in self?.powerChanged(on) }
        client.onFound = { [weak self] list in self?.found = list }
        client.onLinked = { [weak self] in self?.linked() }
        client.onUnlinked = { [weak self] in self?.unlinked() }
        client.onData = { [weak self] d in self?.received(d) }
        client.onCanSend = { [weak self] in self?.pump() }
        client.onTransportChange = { [weak self] in self?.transportChanged() }
    }

    func start() {
        client.start()
        if brain.record != nil {
            screen = .connecting(phoneState.macName ?? "Mac")
            client.connect(toID: phoneState.macID, name: phoneState.macName)
        } else {
            screen = .pickMac
        }
    }

    // MARK: 画面からの操作

    // MARK: 面の色

    private var currentMacID: String? { phoneState.macID ?? client.currentMac?.id.uuidString }

    private func saveColors() {
        if let d = try? JSONEncoder().encode(colorBook) { UserDefaults.standard.set(d, forKey: Self.bookKey) }
    }

    /// 色を選んだ。触った瞬間にその色になる
    func chooseSurface(_ c: SurfaceColor) {
        guard c != surface else { return }
        if currentMacID == nil { colorChosenBeforeMac = c }
        colorBook.choose(c, for: currentMacID)
        saveColors()
        surface = c
        light.impactOccurred(intensity: 0.5)
    }

    func pick(_ mac: BluetoothClient.FoundMac) {
        if let c = colorChosenBeforeMac {
            colorBook.choose(c, for: mac.id.uuidString)
            colorChosenBeforeMac = nil
            saveColors()
        }
        surface = colorBook.color(for: mac.id.uuidString)
        pairingIntent = true
        screen = .connecting(mac.name)
        client.connect(to: mac)
    }

    func submit(code: String) {
        codeMessage = nil
        run(brain.submitCode(code))
    }

    /// 覚えていた Mac を忘れて、選び直す
    func startOver() {
        brain.forget()
        phoneState.master = nil
        phoneState.macID = nil
        phoneState.macName = nil
        keychain.save(phoneState)
        client.forgetTarget()
        pairingIntent = false
        found = []
        screen = .pickMac
    }

    /// もう一度つなぐ
    func retry() {
        if brain.record != nil || phoneState.macID != nil {
            screen = .connecting(phoneState.macName ?? "Mac")
            client.reconnect()
        } else {
            startOver()
        }
    }

    // MARK: Bluetooth からの知らせ

    private func powerChanged(_ on: Bool) {
        if !on { screen = .bluetoothOff } else if screen == .bluetoothOff { start() }
    }

    private func linked() {
        // 覚えた Mac なら挨拶、初めての Mac なら選んだ時だけペアリング
        if brain.record != nil && !pairingIntent {
            run(brain.start())
        } else if pairingIntent {
            run(brain.start(forcePairing: true))
        }
        armStuckTimer()
    }

    private func unlinked() {
        brain.disconnected()
        finishTouches()
        queue.removeAll()
        rawOut.removeAll()
        stopLink()
        stuckWork?.cancel()
        closeDiagnostics()
        if screen != .bluetoothOff, screen != .pickMac {
            screen = .connecting(phoneState.macName ?? "Mac")
        }
    }

    private func received(_ d: Data) {
        run(brain.receive([UInt8](d)))
    }

    /// 挨拶が進まないまま 6 秒たったら、つなぎ直す
    private func armStuckTimer() {
        stuckWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            switch self.brain.state {
            case .hello, .authenticating, .pairingStarted: self.client.reconnect()
            default: break
            }
        }
        stuckWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    // MARK: 頭脳の出力

    private func run(_ outputs: [PhoneBrain.Output]) {
        for o in outputs {
            switch o {
            case let .send(bytes):
                rawOut.append(Data(bytes))
            case let .stateChanged(s):
                stateChanged(s)
            case let .paired(rec):
                phoneState.master = Hex.encode(rec.master)
                phoneState.macID = client.currentMac?.id.uuidString
                phoneState.macName = client.currentMac?.name
                if !keychain.save(phoneState) { saveFailed = true }
                pairingIntent = false
            case let .codeRejected(left):
                codeMessage = "番号が違います（あと \(left) 回）"
            case .retryConnection:
                // 覚えている Mac への挨拶で断られた。画面は変えずに、つなぎ直す（偽の機器に画面を変えさせない）
                client.reconnect()
            case let .macInfo(info):
                // Mac が教えてくれた機種と筐体の色。表で当てられた時だけ、最初の色にする（選んだ色が先）
                if colorBook.learn(info, for: currentMacID) {
                    saveColors()
                    surface = colorBook.color(for: currentMacID)
                }
            case let .pong(token):
                if let sent = pingSent.removeValue(forKey: token) {
                    let ms = (ProcessInfo.processInfo.systemUptime - sent) * 1000
                    rttSamples.append(ms)
                    if rttSamples.count > 60 { rttSamples.removeFirst(rttSamples.count - 60) }
                }
            }
        }
        if saveFailed {
            // つながったのに、この iPhone のキーチェーンに書けなかった。このままだと次に開いた時に忘れているので、
            // つながったことにせず、はじめからにする
            saveFailed = false
            startOver()
            screen = .saveFailed
        }
        pump()
    }

    private func stateChanged(_ s: PhoneBrain.State) {
        switch s {
        case .idle: break
        case .hello, .authenticating: screen = .connecting(phoneState.macName ?? "Mac")
        case .pairingStarted, .confirming: screen = .pairingWait
        case .awaitingCode: codeMessage = nil; screen = .enterCode
        case .ready:
            stuckWork?.cancel()
            screen = .ready
            startLink()
            if preferL2CAP { client.openL2CAP() }
        case .failed(let r):
            stopLink()
            switch r {
            case .unknownDevice: screen = .unknownMac
            case .notPairing: screen = .notPairing
            case .busy: screen = .busy
            case .badMessage: screen = .failed
            }
        case .codeMismatch: screen = .codeMismatch
        }
    }

    // MARK: 指

    /// 面の大きさが変わった（向きが変わった）。縦なら「マウスの形」、横ならトラックパッド。
    func surfaceChanged(size: CGSize) {
        let portrait = size.height > size.width
        if portrait != mouseMode {
            // 向きが変わる時は、押していたものを全部離してから切り替える
            finishTouches()
            mouseMode = portrait
        }
        // 机に寝かせて向きが取れない時は、面の大きさが変わらないので、最後の向きのまま
        engine.mouseLayout = portrait ? MouseLayout(width: Double(size.width), height: Double(size.height)) : nil
    }

    func touches(time: Double, points: [TouchPoint]) {
        guard screen == .ready, !showDiagnostics else { return }
        if !points.isEmpty { light.prepare(); medium.prepare(); heavy.prepare() }
        watchForDiagnostics(count: points.count)
        handle(engine.update(time: time, touches: points))
    }

    /// 4 本指を 0.8 秒押さえ続けたら、確かめ用の表示を開く
    private func watchForDiagnostics(count: Int) {
        if count >= 4 {
            guard diagnosticsWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                self?.diagnosticsWork = nil
                self?.openDiagnostics()
            }
            diagnosticsWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
        } else {
            diagnosticsWork?.cancel()
            diagnosticsWork = nil
        }
    }

    // MARK: 確かめ用の表示（往復時間・送り方）

    func openDiagnostics() {
        finishTouches()
        rttSamples = []
        pingSent = [:]
        showDiagnostics = true
        transportChanged()
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.sendPing() }
    }

    func closeDiagnostics() {
        pingTimer?.invalidate()
        pingTimer = nil
        showDiagnostics = false
    }

    func setPreferL2CAP(_ on: Bool) {
        preferL2CAP = on
        UserDefaults.standard.set(on, forKey: "useL2CAP")
        rttSamples = []
        pingSent = [:]
        if on { client.openL2CAP() } else { client.closeL2CAP() }
        transportChanged()
    }

    private func transportChanged() {
        transportName = client.usingL2CAP ? "L2CAP" : "GATT"
        if preferL2CAP, !client.usingL2CAP {
            l2capNote = client.openingL2CAP ? "L2CAP を開いています" : (client.l2capError ?? "L2CAP はまだ使えません（GATT で送っています）")
        } else {
            l2capNote = nil
        }
        rttSamples = []
        pingSent = [:]
        pump()
    }

    private func sendPing() {
        guard brain.state == .ready else { return }
        let token = nextToken
        nextToken &+= 1
        pingSent[token] = ProcessInfo.processInfo.systemUptime
        if pingSent.count > 20 { pingSent.removeValue(forKey: pingSent.keys.min()!) }
        queue.push(.ping(token: token))
        pump()
    }

    private func finishTouches() {
        let out = engine.update(time: ProcessInfo.processInfo.systemUptime, touches: [])
        // 離した結果（ボタンを離す・ドラッグの終わり）は Mac へ送る。つながっていなければ、あとで捨てられる
        for case let .event(e) in out { queue.push(e) }
        pressedSide = nil
        pump()
    }

    private func handle(_ actions: [GestureAction]) {
        for a in actions {
            switch a {
            case let .event(e): queue.push(e)
            case let .haptic(h):
                switch h {
                case .light: light.impactOccurred()
                case .medium: medium.impactOccurred()
                case .soft: soft.impactOccurred()
                case .release: light.impactOccurred(intensity: 0.6)
                case .heavy:
                    // いちばん強く、短く 2 回（ドラッグに入った合図。クリックのトンより、はっきり違う）
                    heavy.impactOccurred(intensity: 1.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [heavy] in heavy.impactOccurred(intensity: 1.0) }
                }
            }
        }
        if engine.pressedSide != pressedSide { pressedSide = engine.pressedSide }
        pump()
    }

    /// 送れる間だけ送る。詰まったら、移動は足し合わされて溜まる（失わない）
    private func pump() {
        while client.canSend {
            if !rawOut.isEmpty {
                client.write(rawOut.removeFirst())
            } else if brain.state == .ready, let e = queue.pop() {
                guard let packet = brain.seal(e) else { return }
                client.write(Data(packet))
            } else {
                return
            }
        }
    }

    // MARK: 表示の更新（60〜120 回/秒）

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        handle(engine.tick(time: ProcessInfo.processInfo.systemUptime))
    }
}
