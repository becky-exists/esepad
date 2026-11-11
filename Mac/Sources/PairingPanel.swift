import AppKit

/// 新しい iPhone をつなぐ間だけ出る小さな窓。Mac の画面に出た 6 桁を、iPhone に打ってもらう。
final class PairingPanel: NSObject, NSWindowDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                                styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
    private let title = NSTextField(labelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    /// 受付をやめた（「やめる」・窓の ✕）。
    var onCancel: (() -> Void)?
    /// 「つなぐ」を押した（番号の合った確認が届いている時だけ押せる）
    var onApprove: (() -> Void)?
    private let approve = NSButton(title: "つなぐ", target: nil, action: nil)
    private var hiding = false

    override init() {
        super.init()
        panel.title = "esepad"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        code.font = .monospacedDigitSystemFont(ofSize: 52, weight: .semibold)
        code.alignment = .center
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.alignment = .center

        let cancel = NSButton(title: "やめる", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded

        approve.target = self
        approve.action = #selector(approveTapped)
        approve.bezelStyle = .rounded
        approve.keyEquivalent = ""   // Return で押せないようにする（見ずに押してしまわないため）
        approve.isHidden = true
        let buttons = NSStackView(views: [cancel, approve])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [title, code, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        panel.contentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 360),
            note.widthAnchor.constraint(equalToConstant: 312),
        ])
    }

    func showWaiting() {
        approve.isHidden = true
        title.stringValue = "iPhone を待っています"
        code.stringValue = "――――"
        note.stringValue = "iPhone で esepad を開いて、この Mac を選んでください。2 分たつと閉じます。"
        present()
    }

    func show(code c: String) {
        approve.isHidden = true
        title.stringValue = "iPhone に、この番号を入れてください"
        code.stringValue = String(c.prefix(3)) + " " + String(c.suffix(3))
        note.stringValue = "自分の iPhone に esepad の入力欄が出ているときだけ入れてください。"
        present()
    }

    /// 番号の合った確認が届いた。人が見て、「つなぐ」か「やめる」を選ぶ。
    func showApproval(code c: String) {
        title.stringValue = "自分の iPhone に、この番号を打ち終わりましたか？"
        code.stringValue = String(c.prefix(3)) + " " + String(c.suffix(3))
        note.stringValue = "自分の iPhone に、この番号を自分で打ち終えたときだけ「つなぐ」を押してください。打っていない、または心当たりがないときは「やめる」。"
        approve.isHidden = false
        present()
    }

    /// 受付が終わった時（成功・時間切れなど）に閉じる。取り消しとしては扱わない。
    func hide() {
        hiding = true
        panel.orderOut(nil)
        hiding = false
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func approveTapped() {
        onApprove?()
    }

    @objc private func cancel() {
        panel.orderOut(nil)
        onCancel?()
    }

    /// 窓の ✕ で閉じた時も、つなぐ受付をやめる
    func windowWillClose(_ notification: Notification) {
        if !hiding { onCancel?() }
    }
}
