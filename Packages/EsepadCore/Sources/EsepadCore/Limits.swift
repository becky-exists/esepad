import Foundation

/// 時計。壁時計（時刻の同期や手動変更で飛ぶ）ではなく、一方向にだけ進み、スリープの間も進むもの。
/// ペアリングの窓の 120 秒の数え方に使う。
public enum MonotonicClock {
    public static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// 同時に開いておく L2CAP のリンクの数を限る（相手ごとに 64KB の受信の溜めを持つので、際限なく開かせない）。
/// 上限を超えたら、いちばん古いものを閉じる。新しいほうを断ると、切れたまま残った古いリンクが居座って、
/// 本物の iPhone が入れなくなる。L2CAP が閉じても GATT で続けられる。
public struct LinkSlots {
    public let capacity: Int
    private var order: [String] = []

    public init(capacity: Int) { self.capacity = capacity }

    public var keys: [String] { order }

    /// 新しいリンクを入れる。閉じるべき古いリンクの鍵を返す。同じ鍵のやり直しは、並びを新しい側へ動かすだけ
    public mutating func admit(_ key: String) -> [String] {
        order.removeAll { $0 == key }
        order.append(key)
        guard order.count > capacity else { return [] }
        let evicted = Array(order.prefix(order.count - capacity))
        order.removeFirst(evicted.count)
        return evicted
    }

    public mutating func remove(_ key: String) { order.removeAll { $0 == key } }
}
