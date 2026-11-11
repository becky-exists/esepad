import AppKit
import ApplicationServices
import IOKit
import EsepadCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let transport = MacTransport()
    private let pointerController = PointerController()
    /// 操作を出す側。別の実装に入れ替えられる
    private var pointer: PadEventSink { pointerController }
    private let panel = PairingPanel()
    private let defaults = UserDefaults.standard
    private lazy var brain = MacBrain(store: KeychainTrustStore(), now: { MonotonicClock.now() })  // 壁時計ではなく、一方向にだけ進む時計（窓の 120 秒がずれない）

    private var statusItem: NSStatusItem!
    private var pairingTimer: Timer?
    private var connectedPeers = Set<String>()
    private var promptedForAccessibility = false

    private enum Key {
        static let speed = "speed"
        static let accelerate = "accelerate"
        static let reverseScroll = "reverseScroll"
        static let swipeMode = "swipeMode"
    }

    private var speed: Double {
        get { defaults.double(forKey: Key.speed) }
        set { defaults.set(newValue, forKey: Key.speed) }
    }
    private var accelerate: Bool {
        get { defaults.bool(forKey: Key.accelerate) }
        set { defaults.set(newValue, forKey: Key.accelerate) }
    }
    private var swipeMode: PointerController.SwipeMode {
        get { PointerController.SwipeMode(rawValue: defaults.string(forKey: Key.swipeMode) ?? "") ?? .realHorizontalShortcutUp }
        set { defaults.set(newValue.rawValue, forKey: Key.swipeMode) }
    }
    private var reverseScroll: Bool {
        get { defaults.bool(forKey: Key.reverseScroll) }
        set { defaults.set(newValue, forKey: Key.reverseScroll) }
    }

    // MARK: 起動

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: [Key.speed: PointerAcceleration.defaultSpeed, Key.accelerate: true, Key.reverseScroll: false,
                              Key.swipeMode: PointerController.SwipeMode.realHorizontalShortcutUp.rawValue])

        // つながった iPhone に、この Mac の機種と筐体の色を教える（iPhone の面の色の自動に使う）
        brain.macInfo = HostInfo.read()

        // カーソルを動かすには「アクセシビリティ」の許可が要る。最初に 1 度だけ聞く
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        promptedForAccessibility = true
        _ = AXIsProcessTrustedWithOptions(opts)

        pointerController.settings = { [weak self] in
            guard let self = self else {
                return .init(speed: PointerAcceleration.defaultSpeed, accelerate: true, reverseScroll: false, swipeMode: .realHorizontalShortcutUp)
            }
            return .init(speed: self.speed, accelerate: self.accelerate, reverseScroll: self.reverseScroll, swipeMode: self.swipeMode)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        transport.onReceive = { [weak self] peer, bytes in
            guard let self = self else { return }
            self.apply(self.brain.receive(peer: peer, bytes: bytes))
        }
        transport.onDisconnect = { [weak self] peer in
            guard let self = self else { return }
            self.apply(self.brain.peerDisconnected(peer))
            self.connectedPeers.remove(peer)
            self.pointer.releaseAll()
            self.updateIcon()
        }
        transport.onChange = { [weak self] in self?.updateIcon() }
        transport.start()

        panel.onCancel = { [weak self] in
            guard let self = self else { return }
            self.apply(self.brain.closePairing())
        }
        panel.onApprove = { [weak self] in
            guard let self = self else { return }
            self.apply(self.brain.approvePairing())
        }
    }

    // MARK: 頭脳の出力を実行する

    private func apply(_ outputs: [MacBrain.Output]) {
        for o in outputs {
            switch o {
            case let .send(peer, bytes):
                transport.send(peer: peer, bytes: bytes)
            case let .event(_, e):
                pointer.handle(e)
            case let .pairingCode(code):
                panel.show(code: code)
            case let .pairingNeedsApproval(code):
                panel.showApproval(code: code)
            case let .pairingClosed(reason):
                panel.hide()
                pairingTimer?.invalidate()
                pairingTimer = nil
                if reason == .finished { NSSound(named: "Glass")?.play() }
                if reason == .saveFailed { DispatchQueue.main.async { [weak self] in self?.showSaveFailedAlert() } }
            case let .authenticated(peer):
                connectedPeers.insert(peer)
                updateIcon()
            }
        }
    }

    // MARK: メニュー

    private var statusLine: String {
        if !transport.isPoweredOn { return transport.stateText }
        if !connectedPeers.isEmpty { return "iPhone とつながっています" }
        return transport.stateText
    }

    private func updateIcon() {
        // 指でなぞった e（アセットカタログの MenuBarIcon はテンプレート画像。明るい・暗いメニューバーの色は OS が決める）。
        // つながっていない間は、ボタンを無効の見た目（薄く）にする。押せなくはならない（appearsDisabled は見た目だけ）。
        let img = NSImage(named: "MenuBarIcon")
        img?.isTemplate = true
        img?.accessibilityDescription = "esepad"
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = connectedPeers.isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector?, on: Bool = false, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.isEnabled = enabled && sel != nil
            menu.addItem(i)
        }

        add(statusLine, nil)
        if !AXIsProcessTrusted() {
            add("アクセシビリティが未許可です（開いて許可する）", #selector(openAccessibility))
        }
        menu.addItem(.separator())

        let sliderItem = NSMenuItem()
        sliderItem.view = speedView()
        menu.addItem(sliderItem)
        add("加速", #selector(toggleAccelerate), on: accelerate)
        add("スクロールの向きを逆にする", #selector(toggleReverseScroll), on: reverseScroll)

        let swipeItem = NSMenuItem(title: "3 本指のスワイプ", action: nil, keyEquivalent: "")
        let swipeMenu = NSMenu()
        let modes: [(String, PointerController.SwipeMode)] = [
            ("本物のジェスチャー（左右・上とも）", .real),
            ("左右は本物、上は近道", .realHorizontalShortcutUp),
            ("キーボードの近道（Control+矢印）", .shortcut),
        ]
        for (title, mode) in modes {
            let it = NSMenuItem(title: title, action: #selector(setSwipeMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = swipeMode == mode ? .on : .off
            swipeMenu.addItem(it)
        }
        swipeItem.submenu = swipeMenu
        menu.addItem(swipeItem)
        menu.addItem(.separator())

        add("新しい iPhone をつなぐ…", #selector(startPairing), enabled: transport.isPoweredOn)
        let n = (brain.trustedCount)
        add("つないだ iPhone を忘れる（\(n)）", #selector(forgetAll), enabled: n > 0)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "esepad を終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func speedView() -> NSView {
        let label = NSTextField(labelWithString: "速さ")
        label.font = .menuFont(ofSize: 13)
        let slider = NSSlider(value: speed, minValue: 0, maxValue: 1, target: self, action: #selector(speedChanged(_:)))
        slider.isContinuous = true
        let row = NSStackView(views: [label, slider])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        slider.widthAnchor.constraint(equalToConstant: 170).isActive = true
        return row
    }

    @objc private func speedChanged(_ s: NSSlider) { speed = s.doubleValue }
    @objc private func toggleAccelerate() { accelerate.toggle() }
    @objc private func toggleReverseScroll() { reverseScroll.toggle() }
    @objc private func setSwipeMode(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let m = PointerController.SwipeMode(rawValue: raw) { swipeMode = m }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func startPairing() {
        brain.openPairing()
        panel.showWaiting()
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.apply(self.brain.tick())
        }
    }

    @objc private func forgetAll() {
        let alert = NSAlert()
        alert.messageText = "つないだ iPhone をすべて忘れますか？"
        alert.informativeText = "もう一度使うには、iPhone をつなぎ直します。"
        alert.addButton(withTitle: "やめる")
        alert.addButton(withTitle: "忘れる")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        brain.forgetAll()
        connectedPeers.removeAll()
        pointer.releaseAll()
        updateIcon()
    }

    /// 番号は合ったのに、覚えた iPhone をキーチェーンに保存できなかった時。つながったことにはしていない
    private func showSaveFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "iPhone をつなげませんでした"
        alert.informativeText = "つないだ情報をキーチェーンに保存できませんでした。Mac のロックを解除してから、もう一度つないでください。"
        alert.addButton(withTitle: "閉じる")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// この Mac の機種（hw.model）と、筐体の色の生の値（IORegistry の housing-color。無い機種もある）。
/// 色の判断は iPhone 側の表でする。ここでは見つけたものをそのまま渡すだけ。
enum HostInfo {
    static func read() -> MacInfo {
        MacInfo(model: model(), housing: housingColor())
    }

    private static func model() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    private static func housingColor() -> [UInt8] {
        for plane in [kIODeviceTreePlane, kIOServicePlane] {
            let root = IORegistryEntryFromPath(kIOMainPortDefault, "\(plane):/")
            guard root != 0 else { continue }
            defer { IOObjectRelease(root) }
            if let v = IORegistryEntrySearchCFProperty(root, plane, "housing-color" as CFString, kCFAllocatorDefault,
                                                       IOOptionBits(kIORegistryIterateRecursively)) as? Data {
                return [UInt8](v)
            }
        }
        return []
    }
}
