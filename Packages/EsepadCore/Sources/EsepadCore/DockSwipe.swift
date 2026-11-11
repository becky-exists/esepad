import Foundation

/// デスクトップ切り替え・Mission Control のための「本物の 3 本指ジェスチャー」を作る部品（バイト列の部分）。
/// macOS 27 では、合成した Dock のスワイプに、生の IOHID データ（CGEvent のフィールド 4205）を
/// 付けないと効かない。その組み立て方は joshuarli/iss（0BSD）を土台にしている（NOTICE を参照）。
/// 非公開の仕組みなので、将来の macOS で変わると効かなくなる。
public enum DockSwipe {
    public struct Params: Equatable {
        public var phase: Int        // 1 始まり / 2 途中 / 4 終わり
        public var motion: Int       // 1 横 / 2 縦
        public var progress: Double
        public var posX: Double
        public var posY: Double
        public var velX: Double
        public var velY: Double
        public var swipeMask: UInt32
        public var timestamp: UInt64

        public init(phase: Int, motion: Int, progress: Double, posX: Double = 0, posY: Double = 0,
                    velX: Double = 0, velY: Double = 0, swipeMask: UInt32 = 0, timestamp: UInt64) {
            self.phase = phase
            self.motion = motion
            self.progress = progress
            self.posX = posX
            self.posY = posY
            self.velX = velX
            self.velY = velY
            self.swipeMask = swipeMask
            self.timestamp = timestamp
        }
    }

    public static let rawPayloadField: UInt16 = 4205
    static let typeVelocity: UInt32 = 9
    static let typeFluidTouchGesture: UInt32 = 23
    static let flavorDockPrimary: UInt16 = 3

    /// 16.16 の固定小数点。0 でない値が 0 に潰れないようにする。
    public static func fixed1616(_ v: Double) -> Int32 {
        let f = Int32(clamping: Int64(max(-32767, min(32767, v)) * 65536))
        if f == 0 && v != 0 { return v > 0 ? 1 : -1 }
        return f
    }

    /// CGEvent のフィールド 4205 に載せる、生の IOHID データ。
    public static func ioHIDPayload(_ p: Params) -> [UInt8] {
        let includeVelocity = p.velX != 0 || p.velY != 0 || p.phase == 4
        var w = ByteWriter()
        // 列の頭（28 バイト）
        w.u32(UInt32(truncatingIfNeeded: p.timestamp))
        w.u32(UInt32(truncatingIfNeeded: p.timestamp >> 32))
        w.u32(0); w.u32(0)            // 送り主の ID
        w.u32(0)                      // options
        w.u32(0)                      // attribute length
        w.u32(includeVelocity ? 2 : 1)
        // 指の動きのジェスチャー（40 バイト）
        w.u32(40)
        w.u32(typeFluidTouchGesture)
        w.u32(UInt32((p.phase & 0xFF) << 24))
        w.u8(0); w.raw([0, 0, 0])     // depth, 予約
        w.u32(UInt32(bitPattern: fixed1616(p.posX)))
        w.u32(UInt32(bitPattern: fixed1616(p.posY)))
        w.u32(0)                      // position z
        w.u32(p.swipeMask)
        w.u16(UInt16(truncatingIfNeeded: p.motion))
        w.u16(flavorDockPrimary)
        w.u32(UInt32(bitPattern: fixed1616(p.progress)))
        if includeVelocity {
            w.u32(28)
            w.u32(typeVelocity)
            w.u32(0)
            w.u8(1); w.raw([0, 0, 0])
            w.u32(UInt32(bitPattern: fixed1616(p.velX)))
            w.u32(UInt32(bitPattern: fixed1616(p.velY)))
            w.u32(0)
        }
        return w.bytes
    }

    /// 書き出した CGEvent のデータの末尾に、フィールド（4 バイトの印 + 中身）を足す。
    /// 先頭が 00 00 00 02（この形式の版）でなければ nil。
    public static func appendRawField(to serialized: [UInt8], field: UInt16 = rawPayloadField, payload: [UInt8]) -> [UInt8]? {
        guard serialized.count >= 4, Array(serialized[0..<4]) == [0, 0, 0, 2], payload.count <= 0xFFFF else { return nil }
        var out = serialized
        out.append(UInt8(payload.count >> 8))
        out.append(UInt8(payload.count & 0xFF))
        out.append(UInt8(field >> 8))
        out.append(UInt8(field & 0xFF))
        out.append(contentsOf: payload)
        return out
    }

    /// 「右のデスクトップへ」の向きと、段階ごとの値（macOS 27 以降）。
    /// 右へ = 進み具合 -1、左へ = +1。終わりの段階だけ速さをつける（±9999）。
    public static func horizontalPhases(toRight: Bool, timestamp: UInt64) -> [Params] {
        [1, 2, 4].map { phase in
            Params(phase: phase, motion: 1, progress: toRight ? -1.0 : 1.0, posX: 0.1,
                   velX: phase == 4 ? (toRight ? -9999.0 : 9999.0) : 0, timestamp: timestamp)
        }
    }

    /// Mission Control（縦のスワイプ）。向きの符号は実機での確かめが要る（確かめていない）。
    public static func verticalPhases(up: Bool, timestamp: UInt64) -> [Params] {
        [1, 2, 4].map { phase in
            Params(phase: phase, motion: 2, progress: up ? 1.0 : -1.0, posX: 0.1,
                   velY: phase == 4 ? (up ? 9999.0 : -9999.0) : 0, timestamp: timestamp)
        }
    }
}
