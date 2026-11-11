import SwiftUI
import UIKit
import EsepadCore

/// 面の色に合わせた、文字や線の色。明るい面（シルバー・スターライト）では黒系、暗い面では白系。
/// 補助の文字は、面の色ごとに読める濃さ（4.5:1 以上）まで濃くする（スペースグレイは中間の色で、薄い白だと読めない）。
struct Ink {
    let surface: SurfaceColor

    /// 地が明るくて、インクが黒
    var onLight: Bool { surface.inkIsDark }
    var base: Color { onLight ? .black : .white }
    func a(_ opacity: Double) -> Color { base.opacity(opacity) }

    var strong: Color { base.opacity(surface.inkOpacity(preferring: 0.9)) }
    var dim: Color { base.opacity(surface.inkOpacity(preferring: 0.62)) }
    /// 長い数字などの強調。暗い面では明るい緑、明るい面では深い緑
    var accent: Color { onLight ? Color(red: 0.0, green: 0.42, blue: 0.34) : Color(red: 0.36, green: 0.95, blue: 0.72) }
    /// ボタンの地は、面より少し暗くする（面が明るくても暗くても、文字との差が開く）
    var control: Color { Color.black.opacity(onLight ? 0.07 : 0.2) }
    /// 縦置きの場所の目印（ごく薄い差）と、押した時の光り方
    var guide: Color { a(onLight ? 0.045 : 0.06) }
    var guideLine: Color { a(0.10) }
    var pressed: Color { a(0.07) }
}

private struct InkKey: EnvironmentKey { static let defaultValue = Ink(surface: .fallback) }
extension EnvironmentValues {
    fileprivate var ink: Ink {
        get { self[InkKey.self] }
        set { self[InkKey.self] = newValue }
    }
}

extension SurfaceColor {
    fileprivate var color: Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// 隣に置く Mac と同じ色の、のっぺりした面。つながっている間は、何も描かない。
struct RootView: View {
    @StateObject private var model = PadModel()
    @Environment(\.scenePhase) private var scenePhase

    private var ink: Ink { Ink(surface: model.surface) }

    var body: some View {
        ZStack {
            model.surface.color
            PadSurface(model: model)
            if model.screen == .ready && model.mouseMode {
                MouseGuides(model: model).transition(.opacity)
            }
            if model.screen != .ready {
                Overlay(model: model)
                SurfaceDots(model: model, ink: ink)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
            }
            if model.showDiagnostics {
                Diagnostics(model: model).environment(\.colorScheme, .dark).frame(maxWidth: 440).padding(.horizontal, 16)
            }
        }
        // 向きが変わって「マウスの形」の線が出入りする時だけ、ふっと現れる（opacity だけ、0.25 秒）
        .animation(.easeOut(duration: 0.25), value: model.mouseMode)
        // 色を選んだら、その色へすっと変わる
        .animation(.easeOut(duration: 0.2), value: model.surface)
        .environment(\.ink, ink)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(ink.onLight ? .light : .dark)
        .onAppear {
            model.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: scenePhase) { _, p in
            // 使っている間は画面を消さない
            UIApplication.shared.isIdleTimerDisabled = (p == .active)
        }
    }
}

/// 縦に置いた時の「マウスの形」。置いたマウスの左右のボタンの境目に、ごく薄い縦の線を 1 本。文字は出さない。
/// 右端の細い帯（縦になぞるとスクロール）は、ごく薄い明るさの差だけ。
/// トンした側が、一瞬だけ薄く光る（どっちを押したか分かる。触れた瞬間に点き、0.15 秒で消える）。
/// 触れる面ではないので、指は下の面に届く。
private struct MouseGuides: View {
    @ObservedObject var model: PadModel
    @Environment(\.displayScale) private var scale
    @Environment(\.ink) private var ink

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(ink.guide)
                    .frame(width: MouseLayout.defaultEdgeWidth, height: geo.size.height)
                    .offset(x: w - MouseLayout.defaultEdgeWidth)
                press(.left).frame(width: w / 2, height: geo.size.height)
                press(.right).frame(width: w / 2, height: geo.size.height).offset(x: w / 2)
                Rectangle().fill(ink.guideLine).frame(width: 1 / scale, height: geo.size.height).offset(x: w / 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func press(_ side: PadSide) -> some View {
        let on = model.pressedSide == side
        return Rectangle()
            .fill(on ? ink.pressed : Color.clear)
            .animation(on ? .easeOut(duration: 0.05) : .easeOut(duration: 0.15), value: on)
    }
}

private struct Overlay: View {
    @ObservedObject var model: PadModel
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(spacing: 14) {
            switch model.screen {
            case .bluetoothOff:
                note("Bluetooth がオフです", "設定で Bluetooth をオンにして、esepad に許可してください。")
            case .searching:
                note("Mac を探しています", nil)
            case .pickMac:
                PickMac(model: model)
            case let .connecting(name):
                note("\(name) につないでいます", "Mac で esepad が動いているか確かめてください。")
                Button("別の Mac につなぐ") { model.startOver() }.buttonStyle(Quiet())
            case .pairingWait:
                note("確認しています", "Mac の窓に「つなぐ」が出たら、押してください。")
            case .enterCode:
                CodeEntry(model: model)
            case .notPairing:
                note("Mac が、つなぐ準備をしていません",
                     "Mac のメニューバーの esepad から「新しい iPhone をつなぐ…」を選んでから、もう一度。")
                Button("もう一度") { model.startOver() }.buttonStyle(Quiet())
            case .unknownMac:
                note("この Mac は、この iPhone を覚えていません",
                     "Mac の「新しい iPhone をつなぐ…」から、つなぎ直してください。")
                Button("つなぎ直す") { model.startOver() }.buttonStyle(Quiet())
            case .busy:
                note("Mac は別の iPhone とつなぎ中です", nil)
                Button("もう一度") { model.startOver() }.buttonStyle(Quiet())
            case .codeMismatch:
                note("番号が合いませんでした",
                     "近くにほかの機器がいるかもしれません。Mac の窓を閉じて、はじめからやり直してください。")
                Button("はじめから") { model.startOver() }.buttonStyle(Quiet())
            case .failed:
                note("つなげませんでした", nil)
                Button("もう一度") { model.retry() }.buttonStyle(Quiet())
            case .saveFailed:
                note("つないだ情報を、この iPhone に保存できませんでした",
                     "iPhone のロックを解除してから、はじめからやり直してください。")
                Button("はじめから") { model.startOver() }.buttonStyle(Quiet())
            case .ready:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 48)
    }

    private func note(_ title: String, _ body: String?) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(ink.strong)
            if let body = body { Text(body).font(.system(size: 14)).foregroundStyle(ink.dim) }
        }
    }
}

private struct PickMac: View {
    @ObservedObject var model: PadModel
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(spacing: 12) {
            Text("つなぐ Mac を選んでください").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink.strong)
            Text("先に Mac のメニューバーの esepad で「新しい iPhone をつなぐ…」を選びます。")
                .font(.system(size: 14)).foregroundStyle(ink.dim)
            if model.found.isEmpty {
                ProgressView().tint(ink.base).padding(.top, 8)
            }
            ForEach(model.found.prefix(3)) { mac in
                Button { model.pick(mac) } label: {
                    Text(mac.name).font(.system(size: 17, weight: .medium)).frame(maxWidth: 280).padding(.vertical, 12)
                }
                .buttonStyle(Quiet(filled: true))
            }
        }
    }
}

private struct CodeEntry: View {
    @ObservedObject var model: PadModel
    @Environment(\.ink) private var ink
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text("Mac に出ている 6 桁を入れてください").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink.strong)
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(ink.accent)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .onChange(of: text) { _, new in
                    let digits = String(new.filter { $0.isNumber }.prefix(6))
                    if digits != new { text = digits }
                    if digits.count == 6 {
                        model.submit(code: digits)
                        text = ""
                    }
                }
            // 警告は色ではなく、濃さと太さで目立たせる（どの面の色の上でも読めるように）
            if let m = model.codeMessage { Text(m).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink.strong) }
        }
        .onAppear { focused = true }
    }
}

private struct Quiet: ButtonStyle {
    var filled = false
    @Environment(\.ink) private var ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(ink.base.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.horizontal, 18).padding(.vertical, filled ? 0 : 8)
            .background(ink.control, in: Capsule())
    }
}

/// 面の色を選ぶ 4 つの丸。触ったらすぐその色になる。選んでいる色には、外側に輪が付く。
private struct SurfaceDots: View {
    @ObservedObject var model: PadModel
    let ink: Ink
    var showName = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(SurfaceColor.allCases, id: \.self) { c in
                    let on = model.surface == c
                    Button { model.chooseSurface(c) } label: {
                        ZStack {
                            Circle().fill(c.color).frame(width: 28, height: 28)
                            // 丸の縁。明るい色は面に溶けるので、いつも細い縁を引く
                            Circle().stroke(Color.black.opacity(0.28), lineWidth: 1).frame(width: 28, height: 28)
                            if on { Circle().stroke(ink.strong, lineWidth: 2).frame(width: 36, height: 36) }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.displayName)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if showName { Text(model.surface.displayName).font(.system(size: 12)).foregroundStyle(ink.dim) }
        }
    }
}


/// 往復の時間と送り方を確かめるための表示。4 本指を 0.8 秒押さえ続けると開く。
private struct Diagnostics: View {
    @ObservedObject var model: PadModel
    private let cardInk = Ink(surface: .midnight)   // 暗い札なので、面の色に関わらず白い文字

    private var stats: (last: Double, avg: Double, p95: Double, max: Double)? {
        let s = model.rttSamples
        guard let last = s.last else { return nil }
        let sorted = s.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return (last, s.reduce(0, +) / Double(s.count), p95, sorted.last ?? last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("通信の確かめ").font(.system(size: 18, weight: .semibold))
            Picker("送り方", selection: Binding(get: { model.preferL2CAP }, set: { model.setPreferL2CAP($0) })) {
                Text("GATT").tag(false)
                Text("L2CAP").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            Text("いまの送り方: \(model.transportName)").font(.system(size: 14)).foregroundStyle(cardInk.dim)
            if let note = model.l2capNote { Text(note).font(.system(size: 13)).foregroundStyle(.orange) }
            if let s = stats {
                Text(String(format: "往復 最新 %.1f ms / 平均 %.1f / 95%% %.1f / 最大 %.1f（%d 回）",
                            s.last, s.avg, s.p95, s.max, model.rttSamples.count))
                    .font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(cardInk.accent)
            } else {
                Text("往復を測っています…").font(.system(size: 14)).foregroundStyle(cardInk.dim)
            }
            Text("往復の半分が、指からカーソルまでの通信の遅れの目安です。").font(.system(size: 12)).foregroundStyle(cardInk.dim)
            Text("面の色").font(.system(size: 14)).foregroundStyle(cardInk.dim)
            SurfaceDots(model: model, ink: cardInk, showName: true).frame(maxWidth: .infinity)
            Button("閉じる") { model.closeDiagnostics() }.buttonStyle(.bordered).tint(.white)
        }
        .padding(24)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.15)))
        .foregroundStyle(.white)
    }
}
