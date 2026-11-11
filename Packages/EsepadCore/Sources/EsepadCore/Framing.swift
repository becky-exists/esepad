import Foundation

/// L2CAP はバイトの流れなので、1 パケットごとに長さ（2 バイト）を前につけて区切る。
public enum FrameCodec {
    public static let maxPayload = 1024

    public static func encode(_ payload: [UInt8]) -> [UInt8]? {
        guard !payload.isEmpty, payload.count <= maxPayload else { return nil }
        var w = ByteWriter()
        w.u16(UInt16(payload.count))
        w.raw(payload)
        return w.bytes
    }
}

/// 流れてきたバイトから、パケットを取り出す。途中で切れていても、次に来た分とつなげる。
public struct FrameBuffer {
    private var buffer: [UInt8] = []
    /// 長さが不正だった（壊れた・悪意のある流れ）。呼び出し側はチャンネルを閉じる
    public private(set) var corrupt = false

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
        guard !corrupt else { return [] }
        buffer.append(contentsOf: bytes)
        var frames: [[UInt8]] = []
        while buffer.count >= 2 {
            let len = Int(buffer[0]) | (Int(buffer[1]) << 8)
            if len == 0 || len > FrameCodec.maxPayload {
                corrupt = true
                buffer.removeAll()
                return frames
            }
            guard buffer.count >= 2 + len else { break }
            frames.append(Array(buffer[2..<(2 + len)]))
            buffer.removeFirst(2 + len)
        }
        return frames
    }
}
