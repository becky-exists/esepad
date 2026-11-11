import Foundation

/// 送る順番に並べた操作の列。
/// 続けて来た移動とスクロールは 1 つに足し合わせる（Bluetooth が詰まっても指の動きは 1 ミリも失わない）。
/// クリックなどはそのまま順番どおりに残す。
public struct OutboundQueue {
    private var items: [PadEvent] = []
    static let mergeLimit: Float = 3000
    static let capacity = 1024

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public mutating func push(_ e: PadEvent) {
        if let last = items.last {
            switch (last, e) {
            case let (.move(ax, ay, at), .move(bx, by, bt))
                where abs(ax + bx) < Self.mergeLimit && abs(ay + by) < Self.mergeLimit:
                items[items.count - 1] = .move(dx: ax + bx, dy: ay + by, dtMs: min(at + bt, 5000))
                return
            case let (.scroll(.changed, ax, ay), .scroll(.changed, bx, by))
                where abs(ax + bx) < Self.mergeLimit && abs(ay + by) < Self.mergeLimit:
                items[items.count - 1] = .scroll(phase: .changed, dx: ax + bx, dy: ay + by)
                return
            case let (.swipeDrag(.changed, ax, ay), .swipeDrag(.changed, bx, by))
                where abs(ax + bx) < Self.mergeLimit && abs(ay + by) < Self.mergeLimit:
                items[items.count - 1] = .swipeDrag(phase: .changed, dx: ax + bx, dy: ay + by)
                return
            default: break
            }
        }
        items.append(e)
        // 何秒も詰まった時だけ、古いものから捨てる
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }

    public mutating func pop() -> PadEvent? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() { items.removeAll() }
}
