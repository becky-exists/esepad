import Foundation

/// iPhone の面の色。隣に置く MacBook と同じ色にして、黒い板ではなく「Mac の一部」に見せる。
/// 面はのっぺりの単色（Magic Trackpad はガラスで、模様が無い）。値は仮で、実機で見て直す。
public enum SurfaceColor: String, CaseIterable, Codable, Equatable {
    case silver
    case starlight
    case spaceGray
    case midnight

    /// 色が決まっていない時の始まりの色
    public static let fallback = SurfaceColor.spaceGray

    /// 0xRRGGBB
    public var rgb: UInt32 {
        switch self {
        case .silver: return 0xE3E4E6
        case .starlight: return 0xEFE6D8
        case .spaceGray: return 0x6E6F73
        case .midnight: return 0x2E3643
        }
    }

    public var displayName: String {
        switch self {
        case .silver: return "シルバー"
        case .starlight: return "スターライト"
        case .spaceGray: return "スペースグレイ"
        case .midnight: return "ミッドナイト"
        }
    }

    /// 0...1 の相対輝度（WCAG の式）
    public var luminance: Double {
        Self.luminance(r: Double((rgb >> 16) & 0xFF) / 255, g: Double((rgb >> 8) & 0xFF) / 255, b: Double(rgb & 0xFF) / 255)
    }

    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// 面の上に、インク（黒か白、`inkIsDark` で決まる）を不透明度 `a` で重ねた時の、面とのコントラスト比
    public func contrast(inkOpacity a: Double) -> Double {
        let ink = inkIsDark ? 0.0 : 1.0
        func mix(_ shift: UInt32) -> Double { Double((rgb >> shift) & 0xFF) / 255 * (1 - a) + ink * a }
        let over = Self.luminance(r: mix(16), g: mix(8), b: mix(0))
        let (hi, lo) = (max(luminance, over), min(luminance, over))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 文字がコントラスト `ratio` 以上で読める、いちばん薄いインクの不透明度。`preferring` のほうが濃ければそちら。
    /// スペースグレイのような中間の色では、薄い補助文字が読めなくなるので、濃くする
    public func inkOpacity(preferring: Double, atLeast ratio: Double = 4.5) -> Double {
        var a = preferring
        while a < 1, contrast(inkOpacity: a) < ratio { a += 0.01 }
        return min(a, 1)
    }

    /// 面の上の文字や線は、黒と白のうち、面とのコントラストが高いほうにする
    public var inkIsDark: Bool {
        let l = luminance
        let onWhite = 1.05 / (l + 0.05)
        let onBlack = (l + 0.05) / 0.05
        return onBlack > onWhite
    }
}

/// Mac が iPhone に教える、自分のこと（機種と筐体の色）。iPhone が小さい表で 4 色に当てる。
public struct MacInfo: Equatable {
    public var model: String
    /// IORegistry の `housing-color` の生の値（無ければ空）
    public var housing: [UInt8]

    public init(model: String, housing: [UInt8]) {
        self.model = model
        self.housing = housing
    }

    static let maxModel = 32
    static let maxHousing = 32
    /// 暗号化したデータ（Mac → iPhone）の中身の種類
    static let kind: UInt8 = 2

    public func encode() -> [UInt8] {
        let m = Array(model.utf8.prefix(Self.maxModel))
        let h = Array(housing.prefix(Self.maxHousing))
        var w = ByteWriter(Self.kind)
        w.u8(UInt8(m.count))
        w.raw(m)
        w.u8(UInt8(h.count))
        w.raw(h)
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) -> MacInfo? {
        var r = ByteReader(bytes)
        guard r.u8() == kind, let ml = r.u8(), Int(ml) <= maxModel, let m = r.take(Int(ml)),
              let model = String(bytes: m, encoding: .utf8),
              let hl = r.u8(), Int(hl) <= maxHousing, let h = r.take(Int(hl)), r.remaining == 0 else { return nil }
        return MacInfo(model: model, housing: h)
    }

    /// 確かめた組だけを入れた表。推測では当てない（表に無ければ nil）。
    /// 新しい組は、実機で見て確かめてから足す。
    static let knownHousings: [(model: String, housing: String, color: SurfaceColor)] = [
        // 手元の MacBook Pro（MacBookPro18,4）で確かめた値（シルバー）
        ("MacBookPro18,4", "01000000000000000000000001000000", .silver),
    ]

    public var autoColor: SurfaceColor? {
        let hex = Hex.encode(housing)
        return Self.knownHousings.first { $0.model == model && $0.housing == hex }?.color
    }
}

/// 色の覚え書き（iPhone の中、つないだ Mac ごと）。
/// - chosen: 使う人が選んだ色。いちばん強い
/// - derived: Mac が教えてくれた機種と筐体の色から、表で当てた色
/// - last: Mac がまだ決まっていない画面（つなぐ前）で使う、最後の色
public struct SurfaceColorBook: Codable, Equatable {
    public var chosen: [String: SurfaceColor] = [:]
    public var derived: [String: SurfaceColor] = [:]
    public var last: SurfaceColor?

    public init() {}

    /// この Mac の面の色。選んだ色 → 表で当てた色 → スペースグレイ。
    /// Mac がまだ決まっていなければ、最後に使った色。
    public func color(for macID: String?) -> SurfaceColor {
        guard let id = macID else { return last ?? .fallback }
        return chosen[id] ?? derived[id] ?? .fallback
    }

    public mutating func choose(_ c: SurfaceColor, for macID: String?) {
        if let id = macID { chosen[id] = c }
        last = c
    }

    /// Mac の知らせを受けた。表で当てられたら覚える。見た目の色が変わったら true
    @discardableResult
    public mutating func learn(_ info: MacInfo, for macID: String?) -> Bool {
        guard let id = macID, let auto = info.autoColor else { return false }
        let before = color(for: id)
        derived[id] = auto
        if chosen[id] == nil { last = auto }
        return color(for: id) != before
    }

    /// つないでいた Mac を忘れた時
    public mutating func forget(_ macID: String) {
        chosen[macID] = nil
        derived[macID] = nil
    }
}
