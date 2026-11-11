import Foundation

public enum ScrollPhase: UInt8, Equatable {
    case began = 0
    case changed = 1
    /// 指を離した。dx, dy は離す直前の速さ（pt/秒）。
    case ended = 2
}

public enum SwipeDirection: UInt8, Equatable {
    case left = 0
    case right = 1
    case up = 2
}

/// iPhone から Mac へ送る操作。暗号化した「データ」パケットの中身になる。
public enum PadEvent: Equatable {
    /// 指の動き（iPhone の画面上の pt）。dtMs はその間にかかった時間（ミリ秒）。
    case move(dx: Float, dy: Float, dtMs: Float)
    case scroll(phase: ScrollPhase, dx: Float, dy: Float)
    case click
    case rightClick
    case dragBegin
    case dragEnd
    /// 3 本指の払いきった 1 回（古い形。いまの iPhone は swipeDrag を送る。受け取る側は残してある）
    case swipe(SwipeDirection)
    /// 3 本指のスワイプの、指についてくる版。
    /// began の dx, dy は動き始めるまでに動いた量、changed は前回からの動き（pt）、
    /// ended は離す直前の速さ（pt/秒）。
    case swipeDrag(phase: ScrollPhase, dx: Float, dy: Float)
    /// 往復の時間を測るための呼びかけ。Mac が同じ token で返す（操作としては出さない）
    case ping(token: UInt32)
}

extension PadEvent {
    /// 受け取る値の上限。壊れた値や悪意のある値でカーソルが飛ばないように。
    static let maxDelta: Float = 4000
    static let maxVelocity: Float = 100_000
    static let maxDtMs: Float = 6000

    public func encode() -> [UInt8] {
        switch self {
        case let .move(dx, dy, dtMs):
            var w = ByteWriter(1)
            w.f32(dx)
            w.f32(dy)
            // 0.1 ミリ秒単位
            w.u16(UInt16(max(0, min(65535, (dtMs * 10).rounded()))))
            return w.bytes
        case let .scroll(phase, dx, dy):
            var w = ByteWriter(2)
            w.u8(phase.rawValue)
            w.f32(dx)
            w.f32(dy)
            return w.bytes
        case .click: return [3]
        case .rightClick: return [4]
        case .dragBegin: return [5]
        case .dragEnd: return [6]
        case let .swipe(d): return [7, d.rawValue]
        case let .swipeDrag(phase, dx, dy):
            var w = ByteWriter(9)
            w.u8(phase.rawValue)
            w.f32(dx)
            w.f32(dy)
            return w.bytes
        case let .ping(token):
            var w = ByteWriter(8)
            w.u32(token)
            return w.bytes
        }
    }

    public static func decode(_ bytes: [UInt8]) -> PadEvent? {
        var r = ByteReader(bytes)
        guard let kind = r.u8() else { return nil }
        switch kind {
        case 1:
            guard let dx = r.f32(), let dy = r.f32(), let dt = r.u16(), r.remaining == 0,
                  dx.isFinite, dy.isFinite, abs(dx) <= maxDelta, abs(dy) <= maxDelta else { return nil }
            return .move(dx: dx, dy: dy, dtMs: min(Float(dt) / 10, maxDtMs))
        case 2:
            guard let p = r.u8(), let phase = ScrollPhase(rawValue: p),
                  let dx = r.f32(), let dy = r.f32(), r.remaining == 0,
                  dx.isFinite, dy.isFinite else { return nil }
            let limit = phase == .ended ? maxVelocity : maxDelta
            guard abs(dx) <= limit, abs(dy) <= limit else { return nil }
            return .scroll(phase: phase, dx: dx, dy: dy)
        case 3: return r.remaining == 0 ? .click : nil
        case 4: return r.remaining == 0 ? .rightClick : nil
        case 5: return r.remaining == 0 ? .dragBegin : nil
        case 6: return r.remaining == 0 ? .dragEnd : nil
        case 7:
            guard let d = r.u8(), let dir = SwipeDirection(rawValue: d), r.remaining == 0 else { return nil }
            return .swipe(dir)
        case 9:
            guard let p = r.u8(), let phase = ScrollPhase(rawValue: p),
                  let dx = r.f32(), let dy = r.f32(), r.remaining == 0,
                  dx.isFinite, dy.isFinite else { return nil }
            let limit = phase == .ended ? maxVelocity : maxDelta
            guard abs(dx) <= limit, abs(dy) <= limit else { return nil }
            return .swipeDrag(phase: phase, dx: dx, dy: dy)
        case 8:
            guard let t = r.u32(), r.remaining == 0 else { return nil }
            return .ping(token: t)
        default: return nil
        }
    }
}

/// Mac で操作を実際に出す側の差し込み口（カーソル・クリック・スクロール・キー）。
/// 通信（MacBrain / MacTransport）とは、この形でだけつながる。
public protocol PadEventSink: AnyObject {
    func handle(_ e: PadEvent)
    /// つながりが切れた時。押しっぱなし・慣性を片づける
    func releaseAll()
}
