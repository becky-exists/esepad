import Foundation

/// 16 進の文字列とバイト列の変換（保存用）。
public enum Hex {
    public static func encode(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    public static func decode(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let v = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(v)
            i = j
        }
        return out
    }
}

/// iPhone が覚えておくもの。
public struct PhoneState: Codable, Equatable {
    public var deviceID: String
    public var master: String?
    public var macID: String?
    public var macName: String?

    public init(deviceID: String, master: String? = nil, macID: String? = nil, macName: String? = nil) {
        self.deviceID = deviceID
        self.master = master
        self.macID = macID
        self.macName = macName
    }

    public var record: PairingRecord? {
        guard let m = master, let mb = Hex.decode(m), let d = Hex.decode(deviceID) else { return nil }
        return PairingRecord(deviceID: d, master: mb)
    }
}

/// キーチェーンの読み取りの結果。「無い」と「読めなかった」を分ける。
/// （読めなかっただけなのに「無い」として空から始めると、次の保存で元の鍵を消してしまう）
public enum BlobRead: Equatable {
    case found(Data)
    case notFound
    case failed(Int32)
}

/// 1 つだけ値を置く入れ物。本物はキーチェーン、テストでは差し替える。
public protocol BlobStore: AnyObject {
    func read() -> BlobRead
    func write(_ data: Data) -> Bool
    func delete()
}

#if canImport(Security)
import Security

/// キーチェーンに 1 つだけ値を置く。共有鍵は UserDefaults やファイルに平文で置かない。
public final class KeychainBlob: BlobStore {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> BlobRead {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let d = out as? Data else { return .failed(status) }
        return .found(d)
    }

    @discardableResult
    public func write(_ data: Data) -> Bool {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var q = query
        q[kSecValueData as String] = data
        #if os(iOS)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Mac のキーチェーンに、覚えた iPhone の一覧を置く。
public final class KeychainTrustStore: TrustStore {
    private let blob: BlobStore
    private var cache: [String: String] = [:]
    /// 中身を読めた（または、本当に無いと確かめた）か。読めていない間は書き込まない（元の鍵を消さない）
    private var loaded = false

    public convenience init(service: String = "esepad") {
        self.init(blob: KeychainBlob(service: service, account: "trusted-devices"))
    }

    init(blob: BlobStore) {
        self.blob = blob
        loadIfNeeded()
    }

    /// 読めていなければ読み直す（ロック中だった、などが後で直ることがある）。読めたら true。
    @discardableResult
    private func loadIfNeeded() -> Bool {
        if loaded { return true }
        switch blob.read() {
        case .notFound:
            cache = [:]
            loaded = true
        case let .found(d):
            // 形式が読めない時は、壊さないように空から始めない
            guard let m = try? JSONDecoder().decode([String: String].self, from: d) else {
                NSLog("esepad: 覚えた iPhone の一覧を読めません（形式が違います）。上書きしません")
                return false
            }
            cache = m
            loaded = true
        case let .failed(status):
            NSLog("esepad: キーチェーンを読めません（\(status)）。上書きしません")
        }
        return loaded
    }

    public func master(for deviceID: [UInt8]) -> [UInt8]? {
        guard loadIfNeeded() else { return nil }
        return cache[Hex.encode(deviceID)].flatMap(Hex.decode)
    }

    public func save(deviceID: [UInt8], master: [UInt8]) -> Bool {
        guard loadIfNeeded() else { return false }
        var next = cache
        next[Hex.encode(deviceID)] = Hex.encode(master)
        guard let d = try? JSONEncoder().encode(next), blob.write(d) else {
            NSLog("esepad: 覚えた iPhone をキーチェーンに保存できませんでした")
            return false
        }
        cache = next
        return true
    }

    public func forgetAll() {
        cache = [:]
        loaded = true   // 人が「忘れる」と決めたので、空で始めてよい
        blob.delete()
    }

    public var count: Int {
        loadIfNeeded() ? cache.count : 0
    }
}

/// iPhone のキーチェーン。
public final class PhoneKeychain {
    private let blob: BlobStore
    /// 読めなかった時は false。元の状態を新しい ID で上書きしないために、保存を断る
    private var readable = true

    public convenience init() {
        self.init(blob: KeychainBlob(service: "esepad", account: "phone-state"))
    }

    init(blob: BlobStore) { self.blob = blob }

    /// 初めてなら、この iPhone の ID（ランダム 8 バイト）を作って保存する。
    /// 読めなかった時（ロック中・形式が違う）は、保存しない仮の状態を返す。元のデータは消さない。
    public func load(random: RandomSource = SystemRandom()) -> PhoneState {
        switch blob.read() {
        case let .found(d):
            if let s = try? JSONDecoder().decode(PhoneState.self, from: d) { return s }
            readable = false
        case .notFound:
            let s = PhoneState(deviceID: Hex.encode(random.bytes(Secure.deviceIDSize)))
            save(s)
            return s
        case .failed:
            readable = false
        }
        return PhoneState(deviceID: Hex.encode(random.bytes(Secure.deviceIDSize)))
    }

    /// 保存できたら true。読めていない時と、書けなかった時は false。
    @discardableResult
    public func save(_ s: PhoneState) -> Bool {
        guard readable, let d = try? JSONEncoder().encode(s) else { return false }
        return blob.write(d)
    }
}
#endif
