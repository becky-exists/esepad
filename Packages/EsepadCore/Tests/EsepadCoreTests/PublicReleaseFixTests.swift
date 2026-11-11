import XCTest
@testable import EsepadCore

/// 公開前の見直しで見つかった問題（進まない窓の持ち主・窓の時計・断りの扱い・L2CAP の本数の上限）の検査。
final class StalledOwnerTests: XCTestCase {
    private func commit(_ id: UInt8) -> [UInt8] {
        [WireKind.pairCommit] + Array(repeating: id, count: 8) + SystemRandom().bytes(32)
    }

    private func offered(_ outs: [MacBrain.Output], to peer: String) -> Bool {
        outs.contains { if case let .send(p, b) = $0 { return p == peer && b.first == WireKind.pairOffer } else { return false } }
    }

    private func busy(_ peer: String) -> MacBrain.Output {
        .send(peer: peer, bytes: [WireKind.reject, RejectReason.busy.rawValue])
    }

    func testOwnerWhoNeverRevealsIsReleasedAndTheRealPhoneGetsIn() {
        var t = 1000.0
        let mac = MacBrain(store: MemoryTrustStore(), now: { t })
        mac.openPairing()
        XCTAssertTrue(offered(mac.receive(peer: "squatter", bytes: commit(1)), to: "squatter"))
        t += MacBrain.revealLimit - 1
        XCTAssertEqual(mac.receive(peer: "real", bytes: commit(2)), [busy("real")], "15 秒たつ前は使用中")
        t += 1
        let outs = mac.tick()
        XCTAssertEqual(outs, [busy("squatter")], "手放した相手には、使用中を返す")
        XCTAssertTrue(mac.pairingIsOpen, "窓は閉じない")
        XCTAssertTrue(offered(mac.receive(peer: "real", bytes: commit(2)), to: "real"))
    }

    func testReleaseHappensEvenWithoutTheTimer() {
        var t = 1000.0
        let mac = MacBrain(store: MemoryTrustStore(), now: { t })
        mac.openPairing()
        _ = mac.receive(peer: "squatter", bytes: commit(1))
        t += MacBrain.revealLimit + 0.5
        let outs = mac.receive(peer: "real", bytes: commit(2))
        XCTAssertTrue(offered(outs, to: "real"), "タイマーを待たず、来た時に手放す")
        XCTAssertTrue(outs.contains(busy("squatter")))
    }

    func testSamePeerRetryingGetsAnOfferAndNoRejection() {
        var t = 1000.0
        let mac = MacBrain(store: MemoryTrustStore(), now: { t })
        mac.openPairing()
        _ = mac.receive(peer: "phone", bytes: commit(1))
        t += MacBrain.revealLimit + 1
        let outs = mac.receive(peer: "phone", bytes: commit(1))
        XCTAssertTrue(offered(outs, to: "phone"))
        XCTAssertFalse(outs.contains(busy("phone")))
    }

    func testOwnerWhoRevealedIsNotReleasedWhileTypingTheCode() throws {
        var t = 1000.0
        let mac = MacBrain(store: MemoryTrustStore(), now: { t })
        mac.openPairing()
        let phone = PhoneBrain(deviceID: Array(repeating: 7, count: 8), record: nil)
        var toPhone: [[UInt8]] = []
        var toMac: [[UInt8]] = []
        for case let .send(b) in phone.start() { toMac.append(b) }
        while !toMac.isEmpty || !toPhone.isEmpty {
            if !toMac.isEmpty { for case let .send(_, b) in mac.receive(peer: "A", bytes: toMac.removeFirst()) { toPhone.append(b) } }
            if !toPhone.isEmpty { for case let .send(b) in phone.receive(toPhone.removeFirst()) { toMac.append(b) } }
        }
        XCTAssertEqual(phone.state, .awaitingCode)
        t += 100   // 窓（120 秒）の中で、番号を打つのに時間がかかっている
        XCTAssertEqual(mac.tick(), [], "番号を打っている最中の持ち主は手放さない")
        XCTAssertEqual(mac.receive(peer: "B", bytes: commit(2)), [busy("B")])
    }

    func testReleasingIsNotCountedAsAFailure() {
        var t = 1000.0
        let mac = MacBrain(store: MemoryTrustStore(), now: { t })
        mac.openPairing()
        for i in 0..<5 {
            _ = mac.receive(peer: "squatter\(i)", bytes: commit(UInt8(i + 1)))
            t += MacBrain.revealLimit + 1
            _ = mac.tick()
            XCTAssertTrue(mac.pairingIsOpen || t - 1000 >= MacBrain.pairingWindow, "手放しても失敗 3 回では閉じない")
        }
    }
}

final class MonotonicClockTests: XCTestCase {
    func testNeverGoesBackAndMovesForward() {
        let a = MonotonicClock.now()
        Thread.sleep(forTimeInterval: 0.02)
        let b = MonotonicClock.now()
        XCTAssertGreaterThan(a, 0)
        XCTAssertGreaterThanOrEqual(b - a, 0.015)
        XCTAssertLessThan(b - a, 1)
    }
}

final class SilentRetryTests: XCTestCase {
    private func reject(_ r: RejectReason) -> [UInt8] { [WireKind.reject, r.rawValue] }

    private func state(_ outs: [PhoneBrain.Output]) -> [PhoneBrain.State] {
        outs.compactMap { if case let .stateChanged(s) = $0 { return s } else { return nil } }
    }

    func testRejectDuringHelloRetriesQuietlyThenShowsTheRealRefusal() {
        let l = HandshakeTests().pairedLink()
        l.phone.disconnected()
        for i in 1...PhoneBrain.maxSilentRetries {
            _ = l.phone.start()
            XCTAssertEqual(l.phone.state, .hello)
            let outs = l.phone.receive(reject(.unknownDevice))
            XCTAssertEqual(outs, [.retryConnection], "\(i) 回目は画面を変えない")
            XCTAssertEqual(l.phone.state, .hello)
            l.phone.disconnected()
        }
        _ = l.phone.start()
        let last = l.phone.receive(reject(.unknownDevice))
        XCTAssertEqual(state(last), [.failed(.unknownDevice)], "本当に忘れられているなら、数回のあとに画面に出す")
        XCTAssertNotNil(l.phone.record, "断られても、覚えた鍵は消さない")
    }

    func testRejectDuringAuthenticationAlsoRetries() {
        let l = HandshakeTests().pairedLink()
        l.phone.disconnected()
        l.applyPhone(l.phone.start())
        // challenge だけ届けて、認証の途中にする
        l.applyMac(l.mac.receive(peer: "A", bytes: l.toMac.removeFirst()))
        l.applyPhone(l.phone.receive(l.toPhone.removeFirst()))
        XCTAssertEqual(l.phone.state, .authenticating)
        XCTAssertEqual(l.phone.receive(reject(.badMessage)), [.retryConnection])
    }

    func testPairingRefusalsAreShownAtOnce() {
        let phone = PhoneBrain(deviceID: Array(repeating: 7, count: 8), record: nil)
        _ = phone.start()
        XCTAssertEqual(phone.state, .pairingStarted)
        XCTAssertEqual(state(phone.receive(reject(.notPairing))), [.failed(.notPairing)])
        let p2 = PhoneBrain(deviceID: Array(repeating: 7, count: 8), record: nil)
        _ = p2.start()
        XCTAssertEqual(state(p2.receive(reject(.busy))), [.failed(.busy)])
    }

    func testRejectAfterReadyIsIgnored() {
        let l = HandshakeTests().pairedLink()
        XCTAssertEqual(l.phone.state, .ready)
        XCTAssertEqual(l.phone.receive(reject(.unknownDevice)), [])
        XCTAssertEqual(l.phone.state, .ready, "認証のあとに平文で来た断りには、つながりを落とされない")
        XCTAssertNotNil(l.phone.seal(.click))
    }

    func testReadyResetsTheRetryCount() {
        let l = HandshakeTests().pairedLink()
        for _ in 0..<2 {
            l.phone.disconnected()
            _ = l.phone.start()
            XCTAssertEqual(l.phone.receive(reject(.unknownDevice)), [.retryConnection])
        }
        // 本当につながる
        l.phone.disconnected()
        l.phoneOutputs.removeAll()
        l.applyPhone(l.phone.start())
        l.pump()
        XCTAssertEqual(l.phone.state, .ready)
        // つながったあとは、また 3 回まで黙ってつなぎ直す
        for _ in 0..<PhoneBrain.maxSilentRetries {
            l.phone.disconnected()
            _ = l.phone.start()
            XCTAssertEqual(l.phone.receive(reject(.unknownDevice)), [.retryConnection])
        }
    }

    func testMalformedRejectIsIgnored() {
        let phone = PhoneBrain(deviceID: Array(repeating: 7, count: 8), record: nil)
        _ = phone.start()
        XCTAssertEqual(phone.receive([WireKind.reject]), [])
        XCTAssertEqual(phone.receive([WireKind.reject, 99]), [])
        XCTAssertEqual(phone.state, .pairingStarted)
    }
}

final class LinkSlotsTests: XCTestCase {
    func testEvictsTheOldestWhenFull() {
        var s = LinkSlots(capacity: 3)
        XCTAssertEqual(s.admit("a"), [])
        XCTAssertEqual(s.admit("b"), [])
        XCTAssertEqual(s.admit("c"), [])
        XCTAssertEqual(s.admit("d"), ["a"], "いちばん古いものを閉じる")
        XCTAssertEqual(s.keys, ["b", "c", "d"])
    }

    func testSameKeyReopeningDoesNotEvictAnyone() {
        var s = LinkSlots(capacity: 2)
        _ = s.admit("a"); _ = s.admit("b")
        XCTAssertEqual(s.admit("a"), [], "本物の iPhone がつなぎ直しても、他を追い出さない")
        XCTAssertEqual(s.keys, ["b", "a"])
        XCTAssertEqual(s.admit("c"), ["b"], "つなぎ直した側は新しいほうに数える")
    }

    func testRemoveFreesASlot() {
        var s = LinkSlots(capacity: 2)
        _ = s.admit("a"); _ = s.admit("b")
        s.remove("a")
        XCTAssertEqual(s.admit("c"), [])
        XCTAssertEqual(s.keys, ["b", "c"])
    }

    func testFloodKeepsOnlyCapacity() {
        var s = LinkSlots(capacity: 4)
        var closed = 0
        for i in 0..<100 { closed += s.admit("x\(i)").count }
        XCTAssertEqual(s.keys.count, 4)
        XCTAssertEqual(closed, 96)
    }
}
