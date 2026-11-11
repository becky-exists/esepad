import XCTest
import CryptoKit
@testable import EsepadCore

/// Mac が「画面に出した 6 桁」を確かめているかの検査。
/// 番号を知らない機器（近くの攻撃者、途中に割り込んだ第三者）が、Mac に覚えてもらえないことを確かめる。
final class PairingConfirmTests: XCTestCase {

    /// 本物の iPhone を介さず、自分の鍵で Mac と commit → reveal まで進む相手。
    private struct Rogue {
        let id: [UInt8]
        let key: Curve25519.KeyAgreement.PrivateKey
        let pub: [UInt8]
        let nonce: [UInt8]
        let peer: String

        init(id: UInt8 = 0xEE, peer: String = "rogue") throws {
            let rnd = SystemRandom()
            self.id = Array(repeating: id, count: 8)
            key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(rnd.bytes(32)))
            pub = Array(key.publicKey.rawRepresentation)
            nonce = rnd.bytes(16)
            self.peer = peer
        }

        /// commit → reveal まで進め、Mac が画面に出した番号と、自分が導いた鍵を返す
        func pairUntilConfirm(_ mac: MacBrain) throws -> (macCode: String, keys: Secure.PairKeys) {
            let offerOut = mac.receive(peer: peer, bytes: [WireKind.pairCommit] + id + Secure.sha256(pub, nonce))
            guard case let .send(_, offer)? = offerOut.first, offer.first == WireKind.pairOffer else {
                throw XCTSkip("offer が来ない")
            }
            let pubMac = Array(offer[1...])
            let revealOut = mac.receive(peer: peer, bytes: [WireKind.pairReveal] + pub + nonce)
            var shown: String?
            for case let .pairingCode(c) in revealOut { shown = c }
            let keys = try XCTUnwrap(Secure.pairKeys(privateKey: key, peerPublic: pubMac,
                                                     pubPhone: pub, pubMac: pubMac, noncePhone: nonce))
            return (try XCTUnwrap(shown, "Mac の画面に番号が出ていない"), keys)
        }
    }

    private func isRejected(_ outs: [MacBrain.Output], to peer: String) -> Bool {
        outs.contains(.send(peer: peer, bytes: [WireKind.reject, RejectReason.badMessage.rawValue]))
    }

    /// 番号を混ぜずに作った確認（旧来の形。番号を見ていない相手が作れる確認）
    private func confirmWithoutCode(_ keys: Secure.PairKeys) throws -> [UInt8] {
        var s = Sealer(key: keys.phoneToMac)
        return try XCTUnwrap(s.seal(kind: WireKind.pairConfirm, Array("esepad-confirm".utf8)))
    }

    /// 番号を見ていない相手が確認を送っても、Mac は覚えず、窓も閉じる。
    func testConfirmWithoutTheCodeIsRefusedAndWindowCloses() throws {
        let store = MemoryTrustStore()
        let mac = MacBrain(store: store, now: { 1000 })
        mac.openPairing()
        let rogue = try Rogue()
        let (_, keys) = try rogue.pairUntilConfirm(mac)

        let outs = mac.receive(peer: rogue.peer, bytes: try confirmWithoutCode(keys))

        XCTAssertEqual(store.count, 0, "番号を知らない相手を Mac が覚えた")
        XCTAssertTrue(isRejected(outs, to: rogue.peer))
        XCTAssertTrue(outs.contains(.pairingClosed(.confirmMismatch)), "確認の不一致は 1 回で窓を閉じる")
        XCTAssertFalse(mac.pairingIsOpen)
    }

    /// 公開前の見直しでの再現（番号なしで覚えさせる → 窓なしで認証 → クリック）。直したあとは覚えさせられないので、認証で止まる。
    func testRogueCannotAuthenticateOrClickAfterSkippingTheCode() throws {
        let store = MemoryTrustStore()
        let mac = MacBrain(store: store, now: { 1000 })
        mac.openPairing()
        let rogue = try Rogue()
        let (_, keys) = try rogue.pairUntilConfirm(mac)
        _ = mac.receive(peer: rogue.peer, bytes: try confirmWithoutCode(keys))
        mac.peerDisconnected(rogue.peer)

        // 窓は閉じている。覚えさせられていれば、ここから挨拶→認証→クリックが通ってしまう。
        let p2 = "rogue2"
        let nP = SystemRandom().bytes(16)
        let hello = mac.receive(peer: p2, bytes: [WireKind.hello] + rogue.id + nP)
        XCTAssertEqual(hello, [.send(peer: p2, bytes: [WireKind.reject, RejectReason.unknownDevice.rawValue])])
        XCTAssertFalse(mac.isAuthenticated(p2))
    }

    /// 番号を混ぜた確認（本物の iPhone が番号を打ったあとに作るもの）
    private func confirm(_ keys: Secure.PairKeys, code: String) throws -> [UInt8] {
        var s = Sealer(key: Secure.confirmKey(keys.phoneToMac, code: code))
        return try XCTUnwrap(s.seal(kind: WireKind.pairConfirm, Array("esepad-confirm".utf8)))
    }

    /// 番号の合った確認が届いても、Mac は承認待ちになるだけで、覚えない。「つなぐ」を押すと覚えて、完了を返す。
    func testCorrectConfirmWaitsForApprovalThenApproveRemembers() throws {
        let store = MemoryTrustStore()
        let mac = MacBrain(store: store, now: { 1000 })
        mac.openPairing()
        let phone = try Rogue(id: 0x07, peer: "phone")
        let (code, keys) = try phone.pairUntilConfirm(mac)

        let outs = mac.receive(peer: phone.peer, bytes: try confirm(keys, code: code))

        XCTAssertEqual(outs, [.pairingNeedsApproval(code: code)], "番号と「つなぐ」を出すだけ。完了は返さない")
        XCTAssertEqual(store.count, 0, "承認の前は覚えない")
        XCTAssertTrue(mac.pairingIsOpen)

        let approved = mac.approvePairing()

        XCTAssertEqual(store.master(for: phone.id), keys.master)
        XCTAssertTrue(approved.contains { if case let .send(p, b) = $0 { return p == phone.peer && b.first == WireKind.pairDone } else { return false } })
        XCTAssertTrue(approved.contains(.pairingClosed(.finished)))
        XCTAssertFalse(mac.pairingIsOpen)
    }

    /// ずれた番号（1 桁違い）で作った確認は、番号なしと同じく弾く。
    func testConfirmWithAWrongCodeIsRefused() throws {
        let store = MemoryTrustStore()
        let mac = MacBrain(store: store, now: { 1000 })
        mac.openPairing()
        let rogue = try Rogue()
        let (code, keys) = try rogue.pairUntilConfirm(mac)
        let wrong = code == "000000" ? "000001" : "000000"

        let outs = mac.receive(peer: rogue.peer, bytes: try confirm(keys, code: wrong))

        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(isRejected(outs, to: rogue.peer))
        XCTAssertFalse(mac.pairingIsOpen)
    }

}

extension PairingConfirmTests {
    /// 窓が閉じたあとに来た reveal は、何も返さず無視する（Mac は番号を出さない）。
    func testRevealAfterTheWindowClosedIsIgnored() throws {
        var t = 1000.0
        let mac = MacBrain(store: MemoryTrustStore(), now: { t })
        mac.openPairing()
        let rogue = try Rogue()
        _ = mac.receive(peer: rogue.peer, bytes: [WireKind.pairCommit] + rogue.id + Secure.sha256(rogue.pub, rogue.nonce))
        t += MacBrain.pairingWindow + 1

        let outs = mac.receive(peer: rogue.peer, bytes: [WireKind.pairReveal] + rogue.pub + rogue.nonce)

        XCTAssertTrue(outs.isEmpty)
    }

    /// 番号が出たあとで窓が閉じたら、正しい番号で作った確認でも Mac は覚えない。
    func testConfirmAfterTheWindowClosedIsIgnored() throws {
        var t = 1000.0
        let store = MemoryTrustStore()
        let mac = MacBrain(store: store, now: { t })
        mac.openPairing()
        let phone = try Rogue(id: 0x07, peer: "phone")
        let (code, keys) = try phone.pairUntilConfirm(mac)
        t += MacBrain.pairingWindow + 1

        let outs = mac.receive(peer: phone.peer, bytes: try confirm(keys, code: code))

        XCTAssertTrue(outs.isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    /// 確認の不一致で窓を閉じたあとは、本物の iPhone も新しく窓を開けるまで受け付けられない（やり直しは窓を開け直す）。
    func testAfterAConfirmMismatchTheNextCommitIsRefusedUntilReopened() throws {
        let mac = MacBrain(store: MemoryTrustStore(), now: { 1000 })
        mac.openPairing()
        let rogue = try Rogue()
        let (_, keys) = try rogue.pairUntilConfirm(mac)
        _ = mac.receive(peer: rogue.peer, bytes: try confirmWithoutCode(keys))

        let commit = [WireKind.pairCommit] + Array(repeating: UInt8(7), count: 8) + SystemRandom().bytes(32)
        XCTAssertEqual(mac.receive(peer: "phone", bytes: commit),
                       [.send(peer: "phone", bytes: [WireKind.reject, RejectReason.notPairing.rawValue])])
        mac.openPairing()
        XCTAssertEqual(mac.receive(peer: "phone", bytes: commit).count, 1)
        XCTAssertTrue(mac.pairingIsOpen)
    }
}

extension PairingConfirmTests {
    /// 番号を自分で計算できる相手（Mac とペアリングの通信を自分で回す機器、途中に割り込む第三者）の確認は、
    /// Mac に届いても、人が「つなぐ」を押さない限り覚えられない。押さなければ、窓が閉じて捨てられる。
    func testAttackerWhoComputesTheCodeIsNotRememberedWithoutApproval() throws {
        let store = MemoryTrustStore()
        var t = 1000.0
        let mac = MacBrain(store: store, now: { t })
        mac.openPairing()
        let rogue = try Rogue()
        let offerOut = mac.receive(peer: rogue.peer, bytes: [WireKind.pairCommit] + rogue.id + Secure.sha256(rogue.pub, rogue.nonce))
        guard case let .send(_, offer)? = offerOut.first else { return XCTFail("offer が来ない") }
        let pubMac = Array(offer[1...])
        _ = mac.receive(peer: rogue.peer, bytes: [WireKind.pairReveal] + rogue.pub + rogue.nonce)
        // 画面を見ずに、自分の持っている値から番号を計算する（これは防げない。だから人の承認が要る）
        let code = Secure.confirmationCode(pubPhone: rogue.pub, pubMac: pubMac, noncePhone: rogue.nonce)
        let keys = try XCTUnwrap(Secure.pairKeys(privateKey: rogue.key, peerPublic: pubMac,
                                                 pubPhone: rogue.pub, pubMac: pubMac, noncePhone: rogue.nonce))
        var s = Sealer(key: Secure.confirmKey(keys.phoneToMac, code: code))
        let confirm = try XCTUnwrap(s.seal(kind: WireKind.pairConfirm, Array("esepad-confirm".utf8)))

        let outs = mac.receive(peer: rogue.peer, bytes: confirm)

        XCTAssertEqual(outs, [.pairingNeedsApproval(code: code)], "承認待ちになるだけ")
        XCTAssertEqual(store.count, 0, "人が「つなぐ」を押すまで覚えない")
        // 人は、本物の iPhone の画面に番号が出ていないので押さない。窓が閉じると、攻撃者は捨てられて何も覚えられない
        t += MacBrain.pairingWindow + 1
        let closed = mac.tick()
        XCTAssertTrue(closed.contains(.pairingClosed(.expired)))
        XCTAssertTrue(closed.contains(.send(peer: rogue.peer, bytes: [WireKind.reject, RejectReason.badMessage.rawValue])))
        XCTAssertTrue(mac.approvePairing().isEmpty, "窓が閉じたあとの承認は何も起こさない")
        XCTAssertEqual(store.count, 0)
    }
}

/// 保存に失敗する覚え先
private final class FailingStore: TrustStore {
    func master(for deviceID: [UInt8]) -> [UInt8]? { nil }
    func save(deviceID: [UInt8], master: [UInt8]) -> Bool { false }
    func forgetAll() {}
    var count: Int { 0 }
}

extension PairingConfirmTests {
    /// 番号が合っても、保存できなかったら完了を返さない。iPhone に失敗を伝えて、窓を閉じる。
    func testSaveFailureIsNotReportedAsDone() throws {
        let mac = MacBrain(store: FailingStore(), now: { 1000 })
        mac.openPairing()
        let phone = try Rogue(id: 0x07, peer: "phone")
        let (code, keys) = try phone.pairUntilConfirm(mac)

        _ = mac.receive(peer: phone.peer, bytes: try confirm(keys, code: code))
        let outs = mac.approvePairing()

        XCTAssertTrue(isRejected(outs, to: phone.peer))
        XCTAssertFalse(outs.contains { if case let .send(_, b) = $0 { return b.first == WireKind.pairDone } else { return false } })
        XCTAssertTrue(outs.contains(.pairingClosed(.saveFailed)))
    }
}

/// 承認待ちの状態遷移
extension PairingConfirmTests {
    /// 承認待ちまで進めた Mac
    private func waiting(store: TrustStore = MemoryTrustStore(), clock: @escaping () -> TimeInterval = { 1000 }) throws
        -> (mac: MacBrain, rogue: Rogue, keys: Secure.PairKeys, code: String) {
        let mac = MacBrain(store: store, now: clock)
        mac.openPairing()
        let r = try Rogue(id: 0x07, peer: "phone")
        let (code, keys) = try r.pairUntilConfirm(mac)
        XCTAssertEqual(mac.receive(peer: r.peer, bytes: try confirm(keys, code: code)), [.pairingNeedsApproval(code: code)])
        return (mac, r, keys, code)
    }

    private func isRejectSend(_ o: MacBrain.Output, to peer: String) -> Bool {
        o == .send(peer: peer, bytes: [WireKind.reject, RejectReason.badMessage.rawValue])
    }

    /// 承認待ちの間に 2 つ目の確認が来たら、受けずに窓を閉じ、待っていた相手も捨てる。そのあとの承認は何も起こさない。
    func testSecondConfirmWhileWaitingClosesTheWindow() throws {
        let store = MemoryTrustStore()
        let w = try waiting(store: store)

        let outs = w.mac.receive(peer: w.rogue.peer, bytes: try confirm(w.keys, code: w.code))

        XCTAssertTrue(outs.contains(.pairingClosed(.multipleConfirms)))
        XCTAssertTrue(outs.contains { isRejectSend($0, to: w.rogue.peer) })
        XCTAssertFalse(w.mac.pairingIsOpen)
        XCTAssertTrue(w.mac.approvePairing().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    /// 別の相手の確認が来た時も同じ。その相手にも断りを返す。
    func testConfirmFromAnotherPeerWhileWaitingClosesTheWindow() throws {
        let store = MemoryTrustStore()
        let w = try waiting(store: store)
        // 別の機器が、挨拶だけは通した状態（登録済みの相手）で確認を送ってくる
        let knownID = Array(repeating: UInt8(9), count: 8)
        store.save(deviceID: knownID, master: SystemRandom().bytes(32))
        _ = w.mac.receive(peer: "other", bytes: [WireKind.hello] + knownID + SystemRandom().bytes(16))

        let outs = w.mac.receive(peer: "other", bytes: [WireKind.pairConfirm] + SystemRandom().bytes(21 + Secure.tagSize))

        XCTAssertTrue(outs.contains(.pairingClosed(.multipleConfirms)))
        XCTAssertTrue(outs.contains { isRejectSend($0, to: "other") })
        XCTAssertTrue(outs.contains { isRejectSend($0, to: w.rogue.peer) })
        XCTAssertNil(store.master(for: w.rogue.id))
    }

    /// 認証済みの接続が、間違って確認の形のパケットを送ってきても、その接続は落とさない（窓は閉じる）。
    func testStrayConfirmFromAnAuthenticatedPeerKeepsItsSession() throws {
        let store = MemoryTrustStore()
        let w = try waiting(store: store)
        let id = Array(repeating: UInt8(9), count: 8)
        let master = SystemRandom().bytes(32)
        store.save(deviceID: id, master: master)
        let known = PhoneBrain(deviceID: id, record: PairingRecord(deviceID: id, master: master))
        var toMac: [[UInt8]] = []
        for case let .send(b) in known.start() { toMac.append(b) }
        while !toMac.isEmpty {
            for case let .send(_, b) in w.mac.receive(peer: "known", bytes: toMac.removeFirst()) {
                for case let .send(r) in known.receive(b) { toMac.append(r) }
            }
        }
        XCTAssertTrue(w.mac.isAuthenticated("known"))

        let outs = w.mac.receive(peer: "known", bytes: [WireKind.pairConfirm] + SystemRandom().bytes(21 + Secure.tagSize))

        XCTAssertTrue(outs.contains(.pairingClosed(.multipleConfirms)))
        XCTAssertTrue(w.mac.isAuthenticated("known"), "認証済みの接続は落とさない")
    }

    /// 窓が時間で閉じたら、承認待ちの相手を捨てる。
    func testWindowExpiryWhileWaitingDropsThePeer() throws {
        var t = 1000.0
        let store = MemoryTrustStore()
        let w = try waiting(store: store, clock: { t })
        t += MacBrain.pairingWindow + 1

        let outs = w.mac.tick()

        XCTAssertTrue(outs.contains(.pairingClosed(.expired)))
        XCTAssertTrue(outs.contains { isRejectSend($0, to: w.rogue.peer) })
        XCTAssertTrue(w.mac.approvePairing().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    /// 時間切れのあと（tick が来る前）に「つなぐ」を押しても覚えない。
    func testApproveAfterTheDeadlineDoesNothing() throws {
        var t = 1000.0
        let store = MemoryTrustStore()
        let w = try waiting(store: store, clock: { t })
        t += MacBrain.pairingWindow + 1

        XCTAssertTrue(w.mac.approvePairing().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    /// 「やめる」（窓を閉じる）で、承認待ちの相手を捨てる。
    func testCancelWhileWaitingDropsThePeer() throws {
        let store = MemoryTrustStore()
        let w = try waiting(store: store)

        let outs = w.mac.closePairing()

        XCTAssertTrue(outs.contains(.pairingClosed(.cancelled)))
        XCTAssertTrue(outs.contains { isRejectSend($0, to: w.rogue.peer) })
        XCTAssertTrue(w.mac.approvePairing().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    /// 承認待ちの相手が切れたら、窓を閉じる（つなぐ相手がいない）。
    func testPeerDisconnectWhileWaitingClosesTheWindow() throws {
        let store = MemoryTrustStore()
        let w = try waiting(store: store)

        let outs = w.mac.peerDisconnected(w.rogue.peer)

        XCTAssertEqual(outs, [.pairingClosed(.cancelled)])
        XCTAssertTrue(w.mac.approvePairing().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    /// 承認待ちの間は、ほかの iPhone の約束も、同じ相手のやり直しの約束も受けない（busy）。
    func testCommitWhileWaitingIsBusy() throws {
        let w = try waiting()
        let commit = [WireKind.pairCommit] + Array(repeating: UInt8(5), count: 8) + SystemRandom().bytes(32)
        XCTAssertEqual(w.mac.receive(peer: "x", bytes: commit),
                       [.send(peer: "x", bytes: [WireKind.reject, RejectReason.busy.rawValue])])
        XCTAssertEqual(w.mac.receive(peer: w.rogue.peer, bytes: commit),
                       [.send(peer: w.rogue.peer, bytes: [WireKind.reject, RejectReason.busy.rawValue])])
    }

    /// 待っている相手がいなければ、「つなぐ」は何も起こさない。
    func testApproveWithNobodyWaitingDoesNothing() {
        let store = MemoryTrustStore()
        let mac = MacBrain(store: store, now: { 1000 })
        mac.openPairing()
        XCTAssertTrue(mac.approvePairing().isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    /// iPhone は、Mac で「つなぐ」が押されるまで完了を受け取らない（承認前は確認中のまま）。
    func testPhoneStaysConfirmingUntilApproved() {
        let l = Link()
        l.mac.openPairing()
        l.applyPhone(l.phone.start())
        l.pump()
        l.applyPhone(l.phone.submitCode(l.macCode!))
        l.pump()
        XCTAssertEqual(l.phone.state, .confirming)
        XCTAssertEqual(l.store.count, 0)
        XCTAssertTrue(l.macOutputs.contains(.pairingNeedsApproval(code: l.macCode!)))
        l.approve()
        XCTAssertEqual(l.phone.state, .ready)
        XCTAssertEqual(l.store.count, 1)
    }
}
