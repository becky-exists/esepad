import SwiftUI
import UIKit
import EsepadCore

/// 画面いっぱいの、指を受け取るだけの View。判定は EsepadCore の GestureEngine がする。
final class TouchPadView: UIView {
    var onTouches: ((Double, [TouchPoint]) -> Void)?
    var onResize: ((CGSize) -> Void)?

    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear   // 面の色は SwiftUI 側（RootView）で塗る
    }

    required init?(coder: NSCoder) { fatalError("使わない") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onResize?(bounds.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            ids[ObjectIdentifier(t)] = nextID
            nextID += 1
        }
        report(event, touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(event, touches) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(event, touches) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(event, touches) }

    private func finish(_ event: UIEvent?, _ ended: Set<UITouch>) {
        for t in ended { ids.removeValue(forKey: ObjectIdentifier(t)) }
        report(event, ended)
    }

    private func report(_ event: UIEvent?, _ fallback: Set<UITouch>) {
        let all = event?.allTouches ?? fallback
        var points: [TouchPoint] = []
        for t in all {
            guard let id = ids[ObjectIdentifier(t)] else { continue }
            let p = t.location(in: self)
            points.append(TouchPoint(id: id, x: Double(p.x), y: Double(p.y)))
        }
        points.sort { $0.id < $1.id }
        let time = event?.timestamp ?? fallback.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        onTouches?(time, points)
    }
}

struct PadSurface: UIViewRepresentable {
    let model: PadModel

    func makeUIView(context: Context) -> TouchPadView {
        let v = TouchPadView()
        v.onTouches = { [weak model] time, points in model?.touches(time: time, points: points) }
        v.onResize = { [weak model] size in model?.surfaceChanged(size: size) }
        return v
    }

    func updateUIView(_ uiView: TouchPadView, context: Context) {}
}
