import Foundation

/// Bluetooth LE のサービスとキャラクタリスティックの ID。
public enum EsepadBLE {
    /// Mac が広告するサービス
    public static let service = "F30C5161-FE77-4C40-9878-9740A1F59783"
    /// iPhone → Mac（書き込み）
    public static let tx = "67A79324-6FE5-46C7-AB5E-B914E2686298"
    /// Mac → iPhone（通知）
    public static let rx = "151A1DFF-FB56-4F56-ACC6-8F9BE9A7551F"
    /// L2CAP チャンネルの番号（PSM）を読むための値（Mac が置く）
    public static let psm = "A0B7C3D2-5E4F-4A1B-9C2D-3E6F7A8B9C01"
}

/// 1 つ目のバイトで種類を分ける。
public enum WireKind {
    // iPhone → Mac
    public static let hello: UInt8 = 0x01
    public static let pairCommit: UInt8 = 0x02
    public static let pairReveal: UInt8 = 0x03
    public static let pairConfirm: UInt8 = 0x04
    public static let auth: UInt8 = 0x05
    public static let data: UInt8 = 0x10
    // Mac → iPhone
    public static let challenge: UInt8 = 0x81
    public static let pairOffer: UInt8 = 0x82
    public static let pairDone: UInt8 = 0x83
    public static let ready: UInt8 = 0x84
    public static let reject: UInt8 = 0x8F
    /// Mac → iPhone の暗号化したデータ（往復時間の返事）
    public static let macData: UInt8 = 0x90
}

/// Mac が接続を断る理由。
public enum RejectReason: UInt8 {
    case unknownDevice = 0
    case notPairing = 1
    case busy = 2
    case badMessage = 3
}

/// 小さなバイト列の書き手（リトルエンディアン）。
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(_ kind: UInt8? = nil) {
        if let k = kind { bytes.append(k) }
    }

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8(v >> 8))
    }

    mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }

    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    mutating func raw<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
}

/// 範囲外を読んだら nil を返す読み手。
struct ByteReader {
    private let bytes: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - i }

    mutating func u8() -> UInt8? {
        guard i < bytes.count else { return nil }
        defer { i += 1 }
        return bytes[i]
    }

    mutating func u16() -> UInt16? {
        guard i + 2 <= bytes.count else { return nil }
        defer { i += 2 }
        return UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
    }

    mutating func u32() -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(bytes[i + k]) << (8 * UInt32(k)) }
        i += 4
        return v
    }

    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }

    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, i + n <= bytes.count else { return nil }
        defer { i += n }
        return Array(bytes[i..<(i + n)])
    }

    mutating func rest() -> [UInt8] {
        defer { i = bytes.count }
        return Array(bytes[i...])
    }
}
