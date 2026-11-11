import Foundation
import CryptoKit

/// iPhone が覚えておく、ペアリング済みの Mac との共有鍵。
public struct PairingRecord: Equatable {
    public var deviceID: [UInt8]
    public var master: [UInt8]
    public init(deviceID: [UInt8], master: [UInt8]) {
        self.deviceID = deviceID
        self.master = master
    }
}

/// iPhone 側の頭脳。Mac の頭脳（MacBrain）と向かい合う。
public final class PhoneBrain {
    public enum State: Equatable {
        case idle
        case hello
        case authenticating
        case ready
        /// ペアリングを始めて、Mac の返事を待っている
        case pairingStarted
        /// Mac の画面の 6 桁を待っている
        case awaitingCode
        case confirming
        case failed(RejectReason)
        case codeMismatch
    }

    public enum Output: Equatable {
        case send([UInt8])
        case stateChanged(State)
        case paired(PairingRecord)
        case codeRejected(attemptsLeft: Int)
        /// 呼びかけ（ping）への Mac の返事
        case pong(token: UInt32)
        /// Mac が教えてくれた、機種と筐体の色
        case macInfo(MacInfo)
        /// 覚えている Mac への挨拶の途中で断られた。画面には出さずに、つなぎ直す（偽の機器に画面を変えさせないため）。
        /// 続けて `maxSilentRetries` 回まで。それでも断られたら、本当の断りとして `failed` を出す
        case retryConnection
    }

    public static let maxCodeAttempts = 3
    /// 覚えている Mac への挨拶で断られた時に、黙ってつなぎ直す回数（上限）
    public static let maxSilentRetries = 3

    public private(set) var state: State = .idle
    public private(set) var record: PairingRecord?
    public let deviceID: [UInt8]

    private let random: RandomSource

    private var noncePhone: [UInt8] = []
    private var sealer: Sealer?
    private var opener: Opener?

    // ペアリング中だけ使うもの
    private var priv: Curve25519.KeyAgreement.PrivateKey?
    private var pubPhone: [UInt8] = []
    private var pairKeys: Secure.PairKeys?
    private var expectedCode: String?
    private var attempts = 0
    private var silentRetries = 0

    public init(deviceID: [UInt8], record: PairingRecord?, random: RandomSource = SystemRandom()) {
        self.deviceID = deviceID
        self.record = record
        self.random = random
    }

    private func set(_ s: State) -> Output {
        state = s
        return .stateChanged(s)
    }

    /// Bluetooth がつながって通知の購読まで済んだら呼ぶ。
    /// 覚えている Mac があれば挨拶、無ければ（または forcePairing なら）ペアリングから始める。
    public func start(forcePairing: Bool = false) -> [Output] {
        sealer = nil
        opener = nil
        if let rec = record, !forcePairing {
            _ = rec
            noncePhone = random.bytes(Secure.nonceSize)
            return [set(.hello), .send([WireKind.hello] + deviceID + noncePhone)]
        }
        guard let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(random.bytes(32))) else { return [] }
        priv = k
        pubPhone = Array(k.publicKey.rawRepresentation)
        noncePhone = random.bytes(Secure.nonceSize)
        pairKeys = nil
        expectedCode = nil
        attempts = 0
        let commit = Secure.sha256(pubPhone, noncePhone)
        return [set(.pairingStarted), .send([WireKind.pairCommit] + deviceID + commit)]
    }

    /// 切れたら呼ぶ。覚えた Mac は消さない。
    public func disconnected() {
        sealer = nil
        opener = nil
        pairKeys = nil
        priv = nil
        state = .idle
    }

    /// 覚えた Mac を忘れる。
    public func forget() {
        record = nil
        silentRetries = 0
        disconnected()
    }

    // MARK: 受信

    public func receive(_ bytes: [UInt8]) -> [Output] {
        guard let kind = bytes.first else { return [] }
        switch kind {
        case WireKind.challenge: return onChallenge(bytes)
        case WireKind.ready: return onReady(bytes)
        case WireKind.pairOffer: return onOffer(bytes)
        case WireKind.pairDone: return onDone(bytes)
        case WireKind.macData: return onMacData(bytes)
        case WireKind.reject:
            guard bytes.count == 2, let r = RejectReason(rawValue: bytes[1]) else { return [] }
            // 認証が済んだあとの断りは、本物の Mac は送らない（平文で届くので、偽物かもしれない）。無視する
            if state == .ready { return [] }
            // 覚えている Mac への挨拶の途中で断られた時は、まず黙ってつなぎ直す。回数は限る（本当に忘れられている時は、
            // 数回のあとに断りの画面を出す）。ペアリング中の断り（準備ができていない・使用中）は、すぐ画面に出す
            if (state == .hello || state == .authenticating), silentRetries < Self.maxSilentRetries {
                silentRetries += 1
                return [.retryConnection]
            }
            return [set(.failed(r))]
        default: return []
        }
    }

    private func onMacData(_ bytes: [UInt8]) -> [Output] {
        guard state == .ready, var o = opener, let plain = o.open(kind: WireKind.macData, bytes) else { return [] }
        opener = o
        if plain.first == MacInfo.kind {
            return MacInfo.decode(plain).map { [.macInfo($0)] } ?? []
        }
        var r = ByteReader(plain)
        guard r.u8() == 1, let token = r.u32(), r.remaining == 0 else { return [] }
        return [.pong(token: token)]
    }

    private func onChallenge(_ bytes: [UInt8]) -> [Output] {
        guard state == .hello, let rec = record, bytes.count == 1 + Secure.nonceSize else { return [] }
        let nonceMac = Array(bytes[1...])
        let keys = Secure.sessionKeys(master: rec.master, noncePhone: noncePhone, nonceMac: nonceMac)
        var s = Sealer(key: keys.p2m)
        guard let auth = s.seal(kind: WireKind.auth, Array("auth".utf8)) else { return [] }
        sealer = s
        opener = Opener(key: keys.m2p)
        return [set(.authenticating), .send(auth)]
    }

    private func onReady(_ bytes: [UInt8]) -> [Output] {
        guard state == .authenticating, var o = opener,
              let plain = o.open(kind: WireKind.ready, bytes), plain == Array("ready".utf8) else { return [] }
        opener = o
        silentRetries = 0
        return [set(.ready)]
    }

    private func onOffer(_ bytes: [UInt8]) -> [Output] {
        guard state == .pairingStarted, pairKeys == nil, let k = priv, bytes.count == 1 + 32 else { return [] }
        let pubMac = Array(bytes[1...])
        guard let keys = Secure.pairKeys(privateKey: k, peerPublic: pubMac,
                                         pubPhone: pubPhone, pubMac: pubMac, noncePhone: noncePhone) else {
            return [set(.failed(.badMessage))]
        }
        pairKeys = keys
        expectedCode = Secure.confirmationCode(pubPhone: pubPhone, pubMac: pubMac, noncePhone: noncePhone)
        return [set(.awaitingCode), .send([WireKind.pairReveal] + pubPhone + noncePhone)]
    }

    /// ユーザーが打った 6 桁を確かめる。合っていれば Mac へ確認を送る。
    public func submitCode(_ typed: String) -> [Output] {
        guard state == .awaitingCode, let expected = expectedCode, let keys = pairKeys else { return [] }
        let cleaned = typed.filter { $0.isNumber }
        if cleaned == expected {
            var s = Sealer(key: Secure.confirmKey(keys.phoneToMac, code: expected))
            guard let confirm = s.seal(kind: WireKind.pairConfirm, Array("esepad-confirm".utf8)) else { return [] }
            return [set(.confirming), .send(confirm)]
        }
        attempts += 1
        if attempts >= Self.maxCodeAttempts {
            pairKeys = nil
            priv = nil
            return [set(.codeMismatch)]
        }
        return [.codeRejected(attemptsLeft: Self.maxCodeAttempts - attempts)]
    }

    private func onDone(_ bytes: [UInt8]) -> [Output] {
        guard state == .confirming, let keys = pairKeys, let code = expectedCode else { return [] }
        // Mac も同じ番号を知っていることを、完了の鍵で確かめる
        var o = Opener(key: Secure.confirmKey(keys.macToPhone, code: code))
        guard let plain = o.open(kind: WireKind.pairDone, bytes), plain == Array("esepad-done".utf8) else { return [] }
        let rec = PairingRecord(deviceID: deviceID, master: keys.master)
        record = rec
        pairKeys = nil
        priv = nil
        // そのまま普通の接続（挨拶）へ進む
        return [.paired(rec)] + start()
    }

    // MARK: 送信

    /// 操作を暗号化して送る形にする。つながっていなければ nil。
    public func seal(_ event: PadEvent) -> [UInt8]? {
        guard state == .ready, var s = sealer else { return nil }
        guard let packet = s.seal(kind: WireKind.data, event.encode()) else { return nil }
        sealer = s
        return packet
    }
}
