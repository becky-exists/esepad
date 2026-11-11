import Foundation
import CryptoKit

/// 覚えている iPhone の一覧（Mac 側）。本物はキーチェーン、テストではメモリ。
public protocol TrustStore: AnyObject {
    func master(for deviceID: [UInt8]) -> [UInt8]?
    /// 保存できたら true。書けなかったら false（呼ぶ側は「つながった」と言ってはいけない）
    func save(deviceID: [UInt8], master: [UInt8]) -> Bool
    func forgetAll()
    var count: Int { get }
}

public final class MemoryTrustStore: TrustStore {
    private var items: [[UInt8]: [UInt8]] = [:]
    public init() {}
    public func master(for deviceID: [UInt8]) -> [UInt8]? { items[deviceID] }
    @discardableResult
    public func save(deviceID: [UInt8], master: [UInt8]) -> Bool { items[deviceID] = master; return true }
    public func forgetAll() { items = [:] }
    public var count: Int { items.count }
}

public enum PairingCloseReason: Equatable {
    case finished
    case expired
    case tooManyFailures
    /// 確認が合わなかった（番号を知らない相手。本物の iPhone は番号が合った時しか確認を送らない）
    case confirmMismatch
    /// 確認は合ったが、覚えた iPhone をキーチェーンに保存できなかった
    case saveFailed
    /// 承認待ちの間に、2 つ目の確認が届いた（攻撃か不具合。最初の 1 つだけ受けて、窓を閉じる）
    case multipleConfirms
    case cancelled
}

/// Mac 側の頭脳。Bluetooth の受信を渡すと、返す・動かす・画面に出すものを返す。
/// Bluetooth にも画面にも触らないので、テストでそのまま回せる。
public final class MacBrain {
    public enum Output: Equatable {
        case send(peer: String, bytes: [UInt8])
        case event(peer: String, PadEvent)
        /// Mac の画面に出す 6 桁
        case pairingCode(String)
        /// 番号の合った確認が届いた。Mac の画面に、番号と「つなぐ」「やめる」を出す（人が「つなぐ」を押すまで覚えない）
        case pairingNeedsApproval(code: String)
        case pairingClosed(PairingCloseReason)
        case authenticated(peer: String)
    }

    public static let pairingWindow: TimeInterval = 120
    static let maxFailures = 3
    static let maxPeers = 8
    /// 認証もペアリングも進めないまま枠を持っている相手を、この秒数で捨てる
    static let peerIdleLimit: TimeInterval = 30
    /// 窓の持ち主が、約束（commit）から公開（reveal）まで進まずにいていい秒数。過ぎたら持ち主を手放して、次の相手を受ける
    static let revealLimit: TimeInterval = 15

    private struct Pairing {
        var deviceID: [UInt8]
        var commit: [UInt8]
        var privateKey: Curve25519.KeyAgreement.PrivateKey
        var pubMac: [UInt8]
        var keys: Secure.PairKeys?
        /// Mac が画面に出した 6 桁。確認の鍵に混ぜる
        var code: String?
        /// 番号の合った確認が届いて、人の承認を待っている
        var confirmed = false
    }

    private enum PeerState {
        case fresh
        case challenged(master: [UInt8], noncePhone: [UInt8], nonceMac: [UInt8])
        case authenticated(opener: Opener, sealer: Sealer)
        case pairing(Pairing)
    }

    /// つながった iPhone に教える、この Mac の機種と筐体の色（iPhone の面の色の自動に使う）。無ければ何も送らない
    public var macInfo: MacInfo?

    private let store: TrustStore
    private let random: RandomSource
    private let now: () -> TimeInterval
    private var peers: [String: PeerState] = [:]
    /// 相手が枠を取った時刻（捨てる判断にだけ使う。受信のたびには更新しない）
    private var peerSince: [String: TimeInterval] = [:]
    private var pairingDeadline: TimeInterval?
    private var pairingOwner: String?
    /// 持ち主が約束を送った時刻
    private var ownerSince: TimeInterval = 0
    /// 番号の合った確認を送ってきて、Mac の人の承認を待っている相手。いつでも 1 つだけ
    private var approvalPeer: String?
    private var failures = 0

    public init(store: TrustStore, random: RandomSource = SystemRandom(), now: @escaping () -> TimeInterval) {
        self.store = store
        self.random = random
        self.now = now
    }

    // MARK: ペアリングの窓

    public var pairingIsOpen: Bool {
        guard let d = pairingDeadline else { return false }
        return now() < d
    }

    /// 新しい iPhone を受け付ける。120 秒だけ開く。
    public func openPairing() {
        pairingDeadline = now() + Self.pairingWindow
        pairingOwner = nil
        failures = 0
    }

    public func closePairing() -> [Output] {
        guard pairingDeadline != nil else { return [] }
        return closeWindow(.cancelled)
    }

    /// 時間が来たら窓を閉じる。画面側のタイマーから呼ぶ。
    public func tick() -> [Output] {
        purgeStale()
        let released = releaseStalledOwner()
        guard let d = pairingDeadline, now() >= d else { return released }
        return released + closeWindow(.expired)
    }

    /// 窓の持ち主が、約束だけ送って公開に進まないまま `revealLimit` 秒たったら、持ち主を手放す
    /// （進まない相手が、窓の 120 秒ずっと本物の iPhone を締め出すのを防ぐ）。番号を打っている最中（公開のあと）は手放さない。
    /// 意図的に単純化。公開のあと番号を打たずに黙る相手は、窓の時間まで待たせる。上限=120 秒、必要になったら番号の入力にも時間を区切る。
    private func releaseStalledOwner(except peer: String? = nil) -> [Output] {
        guard let owner = pairingOwner, case let .pairing(p)? = peers[owner], p.keys == nil,
              now() - ownerSince >= Self.revealLimit else { return [] }
        peers[owner] = .fresh
        pairingOwner = nil
        // 同じ相手がやり直しに来た時は、断りを送らない（その相手の新しい約束にそのまま答える）
        return owner == peer ? [] : [reject(owner, .busy)]
    }

    private func closeWindow(_ reason: PairingCloseReason) -> [Output] {
        var out: [Output] = []
        // 承認待ちのまま窓が閉じる（やめる・時間切れ・攻撃）なら、待っていた相手を捨てて、断りを返す
        if let waiting = approvalPeer { out.append(reject(waiting, .badMessage)) }
        approvalPeer = nil
        pairingDeadline = nil
        if let o = pairingOwner, case .pairing = peers[o] { peers[o] = .fresh }
        pairingOwner = nil
        return out + [.pairingClosed(reason)]
    }

    private func noteFailure() -> [Output] {
        failures += 1
        if failures >= Self.maxFailures { return closeWindow(.tooManyFailures) }
        return []
    }

    // MARK: 覚えている iPhone

    public var trustedCount: Int { store.count }

    /// 覚えた iPhone を全部忘れる。いま使っている接続も止める。
    public func forgetAll() {
        store.forgetAll()
        for k in peers.keys { peers[k] = .fresh }
    }

    // MARK: 接続

    /// 切れた相手を忘れる。承認待ちの相手が切れたら、つなぐ相手がいなくなるので窓を閉じる。
    @discardableResult
    public func peerDisconnected(_ peer: String) -> [Output] {
        peers.removeValue(forKey: peer)
        peerSince.removeValue(forKey: peer)
        if pairingOwner == peer { pairingOwner = nil }
        if approvalPeer == peer {
            approvalPeer = nil
            return closeWindow(.cancelled)
        }
        return []
    }

    public func isAuthenticated(_ peer: String) -> Bool {
        if case .authenticated = peers[peer] { return true }
        return false
    }

    // MARK: 受信

    public func receive(peer: String, bytes: [UInt8]) -> [Output] {
        guard let kind = bytes.first else { return [] }
        let isNew = peers[peer] == nil
        if isNew {
            // 知らない相手が枠を使えるのは、挨拶かペアリングの約束を送ってきた時だけ。
            // 1 バイト書いただけの相手に枠を取らせない（本物の iPhone が締め出されるのを防ぐ）
            guard kind == WireKind.hello || kind == WireKind.pairCommit else { return [] }
            if peers.count >= Self.maxPeers { purgeStale() }
            guard peers.count < Self.maxPeers else { return [] }
            peers[peer] = .fresh
            peerSince[peer] = now()
        }
        let out: [Output]
        switch kind {
        case WireKind.hello: out = onHello(peer, bytes)
        case WireKind.auth: out = onAuth(peer, bytes)
        case WireKind.data: out = onData(peer, bytes)
        case WireKind.pairCommit: out = onPairCommit(peer, bytes)
        case WireKind.pairReveal: out = onPairReveal(peer, bytes)
        case WireKind.pairConfirm: out = onPairConfirm(peer, bytes)
        default: out = []
        }
        // 形が不正・未登録の機器・窓が閉じている、で何も始まらなかった相手は、枠を残さない
        if isNew, case .fresh? = peers[peer] {
            peers.removeValue(forKey: peer)
            peerSince.removeValue(forKey: peer)
        }
        return out
    }

    /// 認証もペアリングも進めないまま `peerIdleLimit` 秒たった相手を捨てる。
    /// 認証済みの相手と、窓の持ち主（番号を打っている最中）は、窓の時間か切断通知に任せる。
    /// 意図的に単純化。切断の通知が来ない相手を時間で捨てるだけ。上限=最大 8 枠が 30 秒ふさがる、必要になったら相手ごとの回数制限を足す。
    private func purgeStale() {
        let limit = now() - Self.peerIdleLimit
        for (peer, state) in peers {
            guard let since = peerSince[peer], since <= limit else { continue }
            switch state {
            case .authenticated: continue
            case .pairing where peer == pairingOwner: continue
            default:
                peers.removeValue(forKey: peer)
                peerSince.removeValue(forKey: peer)
            }
        }
    }

    private func reject(_ peer: String, _ r: RejectReason) -> Output {
        .send(peer: peer, bytes: [WireKind.reject, r.rawValue])
    }

    private func onHello(_ peer: String, _ bytes: [UInt8]) -> [Output] {
        var r = ByteReader(bytes)
        _ = r.u8()
        guard let id = r.take(Secure.deviceIDSize), let nonceP = r.take(Secure.nonceSize), r.remaining == 0 else {
            return [reject(peer, .badMessage)]
        }
        guard let master = store.master(for: id) else { return [reject(peer, .unknownDevice)] }
        let nonceM = random.bytes(Secure.nonceSize)
        peers[peer] = .challenged(master: master, noncePhone: nonceP, nonceMac: nonceM)
        return [.send(peer: peer, bytes: [WireKind.challenge] + nonceM)]
    }

    private func onAuth(_ peer: String, _ bytes: [UInt8]) -> [Output] {
        guard case let .challenged(master, noncePhone, nonceMac)? = peers[peer] else { return [] }
        let keys = Secure.sessionKeys(master: master, noncePhone: noncePhone, nonceMac: nonceMac)
        var opener = Opener(key: keys.p2m)
        guard let plain = opener.open(kind: WireKind.auth, bytes), plain == Array("auth".utf8) else {
            peers[peer] = .fresh
            return [reject(peer, .unknownDevice)]
        }
        var sealer = Sealer(key: keys.m2p)
        guard let ready = sealer.seal(kind: WireKind.ready, Array("ready".utf8)) else { return [] }
        var out: [Output] = [.send(peer: peer, bytes: ready)]
        // 続けて、この Mac のことを教える（失敗しても、つなぐのには関係ない）
        if let info = macInfo, let packet = sealer.seal(kind: WireKind.macData, info.encode()) {
            out.append(.send(peer: peer, bytes: packet))
        }
        peers[peer] = .authenticated(opener: opener, sealer: sealer)
        return out + [.authenticated(peer: peer)]
    }

    private func onData(_ peer: String, _ bytes: [UInt8]) -> [Output] {
        guard case .authenticated(var opener, var sealer)? = peers[peer] else { return [] }
        // 開けなかったものは黙って捨てる（状態は進めない）
        guard let plain = opener.open(kind: WireKind.data, bytes), let e = PadEvent.decode(plain) else { return [] }
        if case let .ping(token) = e {
            // 往復時間の確かめ。操作としては出さず、暗号化して返す
            var w = ByteWriter(1)
            w.u32(token)
            guard let reply = sealer.seal(kind: WireKind.macData, w.bytes) else { return [] }
            peers[peer] = .authenticated(opener: opener, sealer: sealer)
            return [.send(peer: peer, bytes: reply)]
        }
        peers[peer] = .authenticated(opener: opener, sealer: sealer)
        return [.event(peer: peer, e)]
    }

    // MARK: ペアリング

    private func onPairCommit(_ peer: String, _ bytes: [UInt8]) -> [Output] {
        guard pairingIsOpen else { return [reject(peer, .notPairing)] }
        if approvalPeer != nil { return [reject(peer, .busy)] }
        // 進まない持ち主がいたら、タイマーを待たずにここで手放す
        let released = releaseStalledOwner(except: peer)
        if let o = pairingOwner, o != peer { return released + [reject(peer, .busy)] }
        var r = ByteReader(bytes)
        _ = r.u8()
        guard let id = r.take(Secure.deviceIDSize), let commit = r.take(32), r.remaining == 0,
              let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(random.bytes(32))) else {
            return [reject(peer, .badMessage)]
        }
        pairingOwner = peer
        ownerSince = now()
        let pub = Array(priv.publicKey.rawRepresentation)
        peers[peer] = .pairing(Pairing(deviceID: id, commit: commit, privateKey: priv, pubMac: pub, keys: nil, code: nil))
        return released + [.send(peer: peer, bytes: [WireKind.pairOffer] + pub)]
    }

    private func onPairReveal(_ peer: String, _ bytes: [UInt8]) -> [Output] {
        guard pairingIsOpen, pairingOwner == peer, case var .pairing(p)? = peers[peer], p.keys == nil else { return [] }
        var r = ByteReader(bytes)
        _ = r.u8()
        guard let pubPhone = r.take(32), let nonce = r.take(Secure.nonceSize), r.remaining == 0 else {
            return [reject(peer, .badMessage)]
        }
        // iPhone が最初に約束した公開鍵と同じか確かめる（途中で鍵をすり替えさせない）
        guard Secure.sha256(pubPhone, nonce) == p.commit,
              let keys = Secure.pairKeys(privateKey: p.privateKey, peerPublic: pubPhone,
                                         pubPhone: pubPhone, pubMac: p.pubMac, noncePhone: nonce) else {
            peers[peer] = .fresh
            pairingOwner = nil
            return [reject(peer, .badMessage)] + noteFailure()
        }
        let code = Secure.confirmationCode(pubPhone: pubPhone, pubMac: p.pubMac, noncePhone: nonce)
        p.keys = keys
        p.code = code
        peers[peer] = .pairing(p)
        return [.pairingCode(code)]
    }

    private func onPairConfirm(_ peer: String, _ bytes: [UInt8]) -> [Output] {
        guard pairingIsOpen else { return [] }
        if let waiting = approvalPeer {
            // 承認待ちの間に、2 つ目の確認が届いた。最初の 1 つだけ受けていたので、これは攻撃か不具合。窓を閉じる
            // （待っていた相手への断りは closeWindow が返す。ほかの相手の状態は変えない。認証済みの接続を落とさないため）
            return (peer == waiting ? [] : [reject(peer, .badMessage)]) + closeWindow(.multipleConfirms)
        }
        guard pairingOwner == peer, case var .pairing(p)? = peers[peer],
              let keys = p.keys, let code = p.code else { return [] }
        // 番号を混ぜた鍵でしか開けない。番号を知らない相手の確認はここで弾く
        var opener = Opener(key: Secure.confirmKey(keys.phoneToMac, code: code))
        guard let plain = opener.open(kind: WireKind.pairConfirm, bytes), plain == Array("esepad-confirm".utf8) else {
            // 本物の iPhone は番号が合った時しか確認を送らない。ここに来るのは攻撃か不具合なので、やり直しを許さず 1 回で閉じる
            peers[peer] = .fresh
            return [reject(peer, .badMessage)] + closeWindow(.confirmMismatch)
        }
        // 番号は公開鍵と乱数から決まるので、通信を自分で回す相手も計算できる。確認が合っただけでは覚えない。
        // Mac の人が「自分の iPhone に、この番号を打ち終えた」と確かめて「つなぐ」を押した時（approvePairing）だけ覚える
        p.confirmed = true
        peers[peer] = .pairing(p)
        approvalPeer = peer
        return [.pairingNeedsApproval(code: code)]
    }

    /// Mac の人が「つなぐ」を押した。承認待ちの相手を覚えて、完了を返す。待っている相手がいなければ何もしない。
    public func approvePairing() -> [Output] {
        guard pairingIsOpen, let peer = approvalPeer, case let .pairing(p)? = peers[peer], p.confirmed,
              let keys = p.keys, let code = p.code else { return [] }
        var sealer = Sealer(key: Secure.confirmKey(keys.macToPhone, code: code))
        guard let done = sealer.seal(kind: WireKind.pairDone, Array("esepad-done".utf8)) else { return [] }
        // 保存できなかったのに完了を返すと、iPhone は「つながった」と思い、Mac を再起動すると覚えていない
        guard store.save(deviceID: p.deviceID, master: keys.master) else {
            return closeWindow(.saveFailed)   // 待っていた相手への断りは closeWindow が返す
        }
        approvalPeer = nil
        peers[peer] = .fresh
        return [.send(peer: peer, bytes: done)] + closeWindow(.finished)
    }
}
