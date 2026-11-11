import Foundation
import CryptoKit

/// 乱数の出どころ。テストでは決まった値を返すものに差し替える。
public protocol RandomSource {
    func bytes(_ n: Int) -> [UInt8]
}

public struct SystemRandom: RandomSource {
    public init() {}
    public func bytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
}

/// 暗号まわりの小さな部品。ネットには出ない、Bluetooth の上だけで使う。
enum Secure {
    static let tagSize = 16
    static let deviceIDSize = 8
    static let nonceSize = 16
    static let keySize = 32

    static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: Data(p)) }
        return Array(h.finalize())
    }

    static func hkdf(_ ikm: [UInt8], salt: [UInt8], info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                               salt: Data(salt), info: Data(info.utf8), outputByteCount: keySize)
    }

    static func raw(_ key: SymmetricKey) -> [UInt8] {
        key.withUnsafeBytes { Array($0) }
    }

    /// 6 桁の確認番号。ペアリングの通信全体（両方の公開鍵と iPhone の乱数）から決まる。
    static func confirmationCode(pubPhone: [UInt8], pubMac: [UInt8], noncePhone: [UInt8]) -> String {
        let h = sha256(Array("esepad-sas-v1".utf8), pubPhone, pubMac, noncePhone)
        let n = (UInt32(h[0]) << 24) | (UInt32(h[1]) << 16) | (UInt32(h[2]) << 8) | UInt32(h[3])
        return String(format: "%06d", Int(n % 1_000_000))
    }

    /// ペアリングで 2 台が共有する鍵（マスター）と、その確認に使う 2 本の鍵。
    struct PairKeys {
        let master: [UInt8]
        let phoneToMac: SymmetricKey
        let macToPhone: SymmetricKey
    }

    static func pairKeys(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublic: [UInt8],
                         pubPhone: [UInt8], pubMac: [UInt8], noncePhone: [UInt8]) -> PairKeys? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(peerPublic)),
              let z = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let transcript = sha256(Array("esepad-pair-v1".utf8), pubPhone, pubMac, noncePhone)
        let masterKey = z.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(transcript),
                                                  sharedInfo: Data("esepad master".utf8), outputByteCount: keySize)
        let master = raw(masterKey)
        return PairKeys(master: master,
                        phoneToMac: hkdf(master, salt: transcript, info: "esepad pair p2m"),
                        macToPhone: hkdf(master, salt: transcript, info: "esepad pair m2p"))
    }

    /// 確認（iPhone → Mac）と完了（Mac → iPhone）の鍵に、Mac の画面に出した 6 桁を混ぜる。
    /// 番号を知らない相手は、確認も完了も作れない・開けない（番号は通信に流れない）。
    static func confirmKey(_ k: SymmetricKey, code: String) -> SymmetricKey {
        hkdf(raw(k), salt: Array(code.utf8), info: "esepad confirm")
    }

    /// 接続のたびに作る、その接続だけの鍵。
    static func sessionKeys(master: [UInt8], noncePhone: [UInt8], nonceMac: [UInt8]) -> (p2m: SymmetricKey, m2p: SymmetricKey) {
        let salt = noncePhone + nonceMac
        return (hkdf(master, salt: salt, info: "esepad session p2m"),
                hkdf(master, salt: salt, info: "esepad session m2p"))
    }
}

/// 暗号化して送る側。カウンターを 1 つずつ進める。
struct Sealer {
    let key: SymmetricKey
    private(set) var counter: UInt32

    init(key: SymmetricKey, firstCounter: UInt32 = 0) {
        self.key = key
        self.counter = firstCounter
    }

    /// 種類 1 バイト + カウンター 4 バイト + 暗号文 + 認証タグ 16 バイト
    mutating func seal(kind: UInt8, _ plaintext: [UInt8]) -> [UInt8]? {
        guard counter < UInt32.max else { return nil }
        let c = counter
        counter += 1
        var header = ByteWriter(kind)
        header.u32(c)
        guard let box = try? ChaChaPoly.seal(Data(plaintext), using: key,
                                             nonce: Self.nonce(c), authenticating: Data(header.bytes)) else { return nil }
        return header.bytes + Array(box.ciphertext) + Array(box.tag)
    }

    static func nonce(_ counter: UInt32) -> ChaChaPoly.Nonce {
        var b = [UInt8](repeating: 0, count: 12)
        for i in 0..<4 { b[i] = UInt8((counter >> (8 * UInt32(i))) & 0xFF) }
        // 12 バイトなので失敗しない
        return try! ChaChaPoly.Nonce(data: Data(b))
    }
}

/// 暗号を開く側。古いカウンターや同じカウンターは受け付けない（録音の再生を防ぐ）。
struct Opener {
    let key: SymmetricKey
    private(set) var lastCounter: Int64 = -1

    init(key: SymmetricKey) { self.key = key }

    mutating func open(kind: UInt8, _ packet: [UInt8]) -> [UInt8]? {
        let headerSize = 5
        guard packet.count >= headerSize + Secure.tagSize, packet[0] == kind else { return nil }
        var r = ByteReader(Array(packet[1..<headerSize]))
        guard let counter = r.u32(), Int64(counter) > lastCounter else { return nil }
        let body = Array(packet[headerSize...])
        let ct = Array(body[0..<(body.count - Secure.tagSize)])
        let tag = Array(body[(body.count - Secure.tagSize)...])
        guard let box = try? ChaChaPoly.SealedBox(nonce: Sealer.nonce(counter), ciphertext: Data(ct), tag: Data(tag)),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(packet[0..<headerSize])) else { return nil }
        lastCounter = Int64(counter)
        return Array(plain)
    }
}
