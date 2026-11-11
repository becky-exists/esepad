import XCTest
@testable import EsepadCore

/// Mac の頭脳と iPhone の頭脳を直接つないで回す。
final class Link {
    let store = MemoryTrustStore()
    let mac: MacBrain
    let phone: PhoneBrain
    let peer: String
    var macOutputs: [MacBrain.Output] = []
    var phoneOutputs: [PhoneBrain.Output] = []
    var toMac: [[UInt8]] = []
    var toPhone: [[UInt8]] = []
    /// 通信の途中で書き換えたい時に使う
    var tamperToPhone: (([UInt8]) -> [UInt8])?

    init(peer: String = "A", record: PairingRecord? = nil, macStore: TrustStore? = nil) {
        self.peer = peer
        let box = ClockBox()
        self.box = box
        mac = MacBrain(store: macStore ?? store, now: { box.t })
        phone = PhoneBrain(deviceID: Array(repeating: 7, count: 8), record: record)
    }

    let box: ClockBox
    func advance(_ s: Double) { box.t += s }

    func applyPhone(_ outs: [PhoneBrain.Output]) {
        for o in outs {
            phoneOutputs.append(o)
            if case let .send(b) = o { toMac.append(b) }
        }
    }

    func applyMac(_ outs: [MacBrain.Output]) {
        for o in outs {
            macOutputs.append(o)
            if case let .send(p, b) = o, p == peer {
                toPhone.append(tamperToPhone?(b) ?? b)
            }
        }
    }

    /// Mac の人が「つなぐ」を押す
    func approve() {
        applyMac(mac.approvePairing())
        pump()
    }

    func pump() {
        var guardCount = 0
        while (!toMac.isEmpty || !toPhone.isEmpty) && guardCount < 100 {
            guardCount += 1
            if !toMac.isEmpty { applyMac(mac.receive(peer: peer, bytes: toMac.removeFirst())) }
            if !toPhone.isEmpty { applyPhone(phone.receive(toPhone.removeFirst())) }
        }
    }

    var macCode: String? {
        for o in macOutputs.reversed() { if case let .pairingCode(c) = o { return c } }
        return nil
    }

    var events: [PadEvent] {
        macOutputs.compactMap { if case let .event(_, e) = $0 { return e } else { return nil } }
    }

    /// 覚えている Mac に断られると、iPhone は数回、画面に出さずにつなぎ直す。その回数ぶん繰り返して、断りの画面が出るところまで進める
    func reconnectUntilRefusalIsShown() {
        for _ in 0...PhoneBrain.maxSilentRetries {
            applyPhone(phone.start())
            pump()
            if case .failed = phone.state { return }
            mac.peerDisconnected(peer)
            phone.disconnected()
        }
    }
}

final class ClockBox { var t = 1000.0 }

final class HandshakeTests: XCTestCase {
    /// ペアリングまで済ませた Link を作る
    func pairedLink() -> Link {
        let l = Link()
        l.mac.openPairing()
        l.applyPhone(l.phone.start())
        l.pump()
        XCTAssertEqual(l.phone.state, .awaitingCode)
        l.applyPhone(l.phone.submitCode(l.macCode!))
        l.pump()
        l.approve()
        return l
    }

    func testPairingThenConnectsAndSendsEvents() {
        let l = pairedLink()
        XCTAssertEqual(l.store.count, 1)
        XCTAssertNotNil(l.phone.record)
        XCTAssertEqual(l.phone.state, .ready, "ペアリングのあと、そのまま使える状態になる")
        XCTAssertFalse(l.mac.pairingIsOpen, "1 回ペアリングしたら窓は閉じる")

        for e in [PadEvent.move(dx: 5, dy: -3, dtMs: 8), .click, .swipe(.up)] {
            let packet = l.phone.seal(e)!
            l.applyMac(l.mac.receive(peer: "A", bytes: packet))
        }
        XCTAssertEqual(l.events, [.move(dx: 5, dy: -3, dtMs: 8), .click, .swipe(.up)])
    }

    func testPairingRefusedWhenWindowClosed() {
        let l = Link()
        l.applyPhone(l.phone.start())
        l.pump()
        XCTAssertEqual(l.phone.state, .failed(.notPairing))
        XCTAssertEqual(l.store.count, 0)
        XCTAssertNil(l.macCode)
    }

    func testPairingWindowExpires() {
        let l = Link()
        l.mac.openPairing()
        l.advance(MacBrain.pairingWindow + 1)
        XCTAssertEqual(l.mac.tick(), [.pairingClosed(.expired)])
        l.applyPhone(l.phone.start())
        l.pump()
        XCTAssertEqual(l.phone.state, .failed(.notPairing))
    }

    func testWrongCodeIsRejectedAndNothingIsStored() {
        let l = Link()
        l.mac.openPairing()
        l.applyPhone(l.phone.start())
        l.pump()
        let wrong = l.macCode! == "000000" ? "111111" : "000000"
        l.applyPhone(l.phone.submitCode(wrong))
        XCTAssertEqual(l.phoneOutputs.last, .codeRejected(attemptsLeft: 2))
        l.applyPhone(l.phone.submitCode(wrong))
        l.applyPhone(l.phone.submitCode(wrong))
        XCTAssertEqual(l.phone.state, .codeMismatch)
        l.pump()
        XCTAssertEqual(l.store.count, 0)
        XCTAssertNil(l.phone.record)
        // もう確認は送れない
        XCTAssertTrue(l.phone.submitCode(l.macCode!).isEmpty)
    }

    func testTypoThenCorrectCodeStillPairs() {
        let l = Link()
        l.mac.openPairing()
        l.applyPhone(l.phone.start())
        l.pump()
        let wrong = l.macCode! == "000000" ? "111111" : "000000"
        l.applyPhone(l.phone.submitCode(wrong))
        l.applyPhone(l.phone.submitCode(l.macCode!))
        l.pump()
        l.approve()
        XCTAssertEqual(l.store.count, 1)
        XCTAssertEqual(l.phone.state, .ready)
    }

    func testCodeAcceptsSpacesAndDashes() {
        let l = Link()
        l.mac.openPairing()
        l.applyPhone(l.phone.start())
        l.pump()
        let c = l.macCode!
        let spaced = c.prefix(3) + " " + c.suffix(3)
        l.applyPhone(l.phone.submitCode(String(spaced)))
        l.pump()
        l.approve()
        XCTAssertEqual(l.phone.state, .ready)
    }

    /// 途中に割り込んだ第三者が公開鍵をすり替えると、Mac に出る番号と iPhone が期待する番号がずれる。
    /// iPhone は確認を送らず、割り込んだ側が偽の確認を Mac へ送っても Mac は覚えず、窓も閉じる。
    /// （割り込んだ側が自分と Mac の間の番号を計算できる場合は防げない。PairingConfirmTests の既知の限界を参照）
    func testManInTheMiddleDoesNotGetThePhoneToConfirmAndMacRefusesAForgedConfirm() {
        let l = Link()
        l.mac.openPairing()
        // iPhone の約束を Mac へ
        l.applyPhone(l.phone.start())
        l.applyMac(l.mac.receive(peer: "A", bytes: l.toMac.removeFirst()))
        // Mac の返事（公開鍵）を、攻撃者の公開鍵に差し替えて iPhone へ
        l.toPhone.removeAll()
        let attacker = SystemRandom().bytes(32)
        let fakeOffer = [WireKind.pairOffer] + attacker
        l.applyPhone(l.phone.receive(fakeOffer))
        // iPhone の公開（reveal）はそのまま Mac へ届く。約束どおりなので Mac は通す
        l.applyMac(l.mac.receive(peer: "A", bytes: l.toMac.removeFirst()))
        let macShows = l.macCode
        XCTAssertNotNil(macShows, "Mac には番号が出る")
        // ユーザーが Mac の番号を打っても、iPhone は一致と見なさず、確認を送らない
        l.toMac.removeAll()
        l.applyPhone(l.phone.submitCode(macShows!))
        XCTAssertNotEqual(l.phone.state, .confirming)
        XCTAssertFalse(l.toMac.contains { $0.first == WireKind.pairConfirm }, "iPhone は確認を送っていない")
        XCTAssertEqual(l.store.count, 0)
        // 割り込んだ側が、確認のふりをした偽のパケットを Mac へ送る。Mac は覚えず、その 1 回で窓を閉じる
        let forged = [WireKind.pairConfirm] + SystemRandom().bytes(4) + SystemRandom().bytes(21 + Secure.tagSize)
        let out = l.mac.receive(peer: "A", bytes: forged)
        XCTAssertTrue(out.contains(.send(peer: "A", bytes: [WireKind.reject, RejectReason.badMessage.rawValue])))
        XCTAssertTrue(out.contains(.pairingClosed(.confirmMismatch)))
        XCTAssertEqual(l.store.count, 0, "Mac は割り込んだ側を覚えていない")
        XCTAssertFalse(l.mac.pairingIsOpen)
    }

    func testRevealThatDoesNotMatchCommitmentIsRefused() {
        let l = Link()
        l.mac.openPairing()
        l.applyPhone(l.phone.start())
        l.applyMac(l.mac.receive(peer: "A", bytes: l.toMac.removeFirst()))
        // 約束した鍵とは別の鍵を明かす
        let other = SystemRandom().bytes(32)
        let out = l.mac.receive(peer: "A", bytes: [WireKind.pairReveal] + other + SystemRandom().bytes(16))
        XCTAssertTrue(out.contains(.send(peer: "A", bytes: [WireKind.reject, RejectReason.badMessage.rawValue])))
        XCTAssertNil(l.macCode)
    }

    func testThreeFailuresCloseThePairingWindow() {
        let l = Link()
        l.mac.openPairing()
        var closed = false
        for i in 0..<3 {
            let peer = "P\(i)"
            _ = l.mac.receive(peer: peer, bytes: [WireKind.pairCommit] + Array(repeating: 1, count: 8) + SystemRandom().bytes(32))
            let out = l.mac.receive(peer: peer, bytes: [WireKind.pairReveal] + SystemRandom().bytes(32) + SystemRandom().bytes(16))
            if out.contains(.pairingClosed(.tooManyFailures)) { closed = true }
            l.mac.peerDisconnected(peer)
        }
        XCTAssertTrue(closed)
        XCTAssertFalse(l.mac.pairingIsOpen)
    }

    func testSecondPhoneIsToldBusyWhilePairing() {
        let l = Link()
        l.mac.openPairing()
        _ = l.mac.receive(peer: "A", bytes: [WireKind.pairCommit] + Array(repeating: 1, count: 8) + SystemRandom().bytes(32))
        let out = l.mac.receive(peer: "B", bytes: [WireKind.pairCommit] + Array(repeating: 2, count: 8) + SystemRandom().bytes(32))
        XCTAssertEqual(out, [.send(peer: "B", bytes: [WireKind.reject, RejectReason.busy.rawValue])])
    }

    func testUnknownDeviceIsRejectedAndNeverAuthenticated() {
        let l = Link(record: PairingRecord(deviceID: Array(repeating: 7, count: 8), master: SystemRandom().bytes(32)))
        l.reconnectUntilRefusalIsShown()
        XCTAssertEqual(l.phone.state, .failed(.unknownDevice))
        XCTAssertFalse(l.macOutputs.contains { if case .authenticated = $0 { return true } else { return false } })
    }

    func testReconnectUsesStoredKeyAndNeedsNoWindow() {
        let l = pairedLink()
        // 切れて、つなぎ直す
        l.mac.peerDisconnected("A")
        l.phone.disconnected()
        l.macOutputs.removeAll()
        l.applyPhone(l.phone.start())
        l.pump()
        XCTAssertEqual(l.phone.state, .ready)
        XCTAssertTrue(l.mac.isAuthenticated("A"))
        XCTAssertFalse(l.mac.pairingIsOpen)
    }

    func testWrongKeyCannotAuthenticate() {
        let l = pairedLink()
        let stolenID = l.phone.deviceID
        let imposter = PhoneBrain(deviceID: stolenID, record: PairingRecord(deviceID: stolenID, master: SystemRandom().bytes(32)))
        var toMac = imposter.start()
        guard case let .send(hello)? = toMac.first(where: { if case .send = $0 { return true } else { return false } }) else { return XCTFail() }
        let ch = l.mac.receive(peer: "X", bytes: hello)
        guard case let .send(_, chBytes)? = ch.first else { return XCTFail() }
        toMac = imposter.receive(chBytes)
        guard case let .send(auth)? = toMac.first(where: { if case .send = $0 { return true } else { return false } }) else { return XCTFail() }
        let result = l.mac.receive(peer: "X", bytes: auth)
        XCTAssertEqual(result, [.send(peer: "X", bytes: [WireKind.reject, RejectReason.unknownDevice.rawValue])])
        XCTAssertFalse(l.mac.isAuthenticated("X"))
    }

    func testReplayedAndTamperedPacketsAreIgnored() {
        let l = pairedLink()
        let p1 = l.phone.seal(.click)!
        l.applyMac(l.mac.receive(peer: "A", bytes: p1))
        XCTAssertEqual(l.events, [.click])
        // 同じものをもう一度（録音の再生）
        l.applyMac(l.mac.receive(peer: "A", bytes: p1))
        XCTAssertEqual(l.events, [.click])
        // 1 ビット書き換え
        var p2 = l.phone.seal(.rightClick)!
        p2[p2.count - 1] ^= 1
        l.applyMac(l.mac.receive(peer: "A", bytes: p2))
        XCTAssertEqual(l.events, [.click])
        // 本物の次は通る（書き換えで状態が壊れていない）
        l.applyMac(l.mac.receive(peer: "A", bytes: l.phone.seal(.dragBegin)!))
        XCTAssertEqual(l.events, [.click, .dragBegin])
    }

    func testPacketsFromADifferentSessionAreIgnored() {
        let l = pairedLink()
        let old = l.phone.seal(.click)!
        l.mac.peerDisconnected("A"); l.phone.disconnected()
        l.applyPhone(l.phone.start()); l.pump()
        XCTAssertEqual(l.phone.state, .ready)
        l.macOutputs.removeAll()
        l.applyMac(l.mac.receive(peer: "A", bytes: old))
        XCTAssertTrue(l.events.isEmpty, "前の接続で盗み聞いたものは、今の接続では通らない")
    }

    func testDataBeforeAuthenticationIsIgnored() {
        let l = pairedLink()
        let packet = l.phone.seal(.click)!
        // 別の（未認証の）相手から同じ内容が届いても動かさない
        XCTAssertTrue(l.mac.receive(peer: "stranger", bytes: packet).isEmpty)
        XCTAssertTrue(l.mac.receive(peer: "stranger", bytes: [WireKind.data] + Array(repeating: 0, count: 30)).isEmpty)
    }

    func testFakeMacCannotMakePhoneReady() {
        let record = PairingRecord(deviceID: Array(repeating: 7, count: 8), master: SystemRandom().bytes(32))
        let phone = PhoneBrain(deviceID: record.deviceID, record: record)
        _ = phone.start()
        _ = phone.receive([WireKind.challenge] + SystemRandom().bytes(16))
        XCTAssertEqual(phone.state, .authenticating)
        // 鍵を知らない偽の Mac が「ready」らしいものを返しても通らない
        _ = phone.receive([WireKind.ready] + SystemRandom().bytes(5 + 16 + 5))
        XCTAssertEqual(phone.state, .authenticating)
        XCTAssertNil(phone.seal(.click))
    }

    func testEventsNeedTheConnectionToBeReady() {
        let phone = PhoneBrain(deviceID: Array(repeating: 1, count: 8), record: nil)
        XCTAssertNil(phone.seal(.click))
    }

    func testForgetMakesPhoneStartPairingAgain() {
        let l = pairedLink()
        l.phone.forget()
        l.mac.openPairing()
        let outs = l.phone.start()
        XCTAssertEqual(l.phone.state, .pairingStarted)
        XCTAssertTrue(outs.contains { if case let .send(b) = $0 { return b.first == WireKind.pairCommit } else { return false } })
    }

    func testForgettingAllStopsTheConnectionAndRefusesReconnect() {
        let l = pairedLink()
        XCTAssertEqual(l.mac.trustedCount, 1)
        l.mac.forgetAll()
        XCTAssertEqual(l.mac.trustedCount, 0)
        XCTAssertTrue(l.mac.receive(peer: "A", bytes: l.phone.seal(.click)!).isEmpty, "いまの接続も使えなくなる")
        l.mac.peerDisconnected("A"); l.phone.disconnected()
        l.reconnectUntilRefusalIsShown()
        XCTAssertEqual(l.phone.state, .failed(.unknownDevice))
    }
}

/// 暗号の処理が、指とカーソルの遅れに足す時間の目安。
final class CostTests: XCTestCase {
    func testSealAndOpenCostPerPacket() {
        let key = Secure.hkdf([1, 2, 3], salt: [4], info: "bench")
        var sealer = Sealer(key: key, firstCounter: 1)
        var opener = Opener(key: key)
        let payload = PadEvent.move(dx: 3, dy: -2, dtMs: 8).encode()
        let n = 5000
        let start = Date()
        for _ in 0..<n {
            let p = sealer.seal(kind: WireKind.data, payload)!
            XCTAssertNotNil(opener.open(kind: WireKind.data, p))
        }
        let perPacketMicros = Date().timeIntervalSince(start) / Double(n) * 1_000_000
        print("暗号化+復号 1 パケットあたり: \(Int(perPacketMicros)) マイクロ秒（デバッグビルド）")
        XCTAssertLessThan(perPacketMicros, 500, "遅れとして気にならない大きさ")
    }

    func testPacketSizesFitInSmallBluetoothWrites() {
        var s = Sealer(key: Secure.hkdf([1], salt: [2], info: "x"), firstCounter: 1)
        let move = s.seal(kind: WireKind.data, PadEvent.move(dx: 1, dy: 1, dtMs: 8).encode())!
        XCTAssertLessThanOrEqual(move.count, 40)
        // 初期の Bluetooth の最小の書き込み幅（20 バイト）には入らないが、通常の 182 バイトには十分余裕がある
        XCTAssertLessThan(move.count, 182)
    }
}
