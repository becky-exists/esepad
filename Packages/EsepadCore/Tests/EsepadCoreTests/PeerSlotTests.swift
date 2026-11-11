import XCTest
@testable import EsepadCore

/// 購読も切断通知もない相手で `MacBrain` の枠がふさがり、本物の iPhone が締め出されないことの検査。
final class PeerSlotTests: XCTestCase {
    private func phoneHello() -> [UInt8] {
        let phone = PhoneBrain(deviceID: Array(repeating: 7, count: 8), record: nil)
        // record が無いのでペアリングの約束（commit）が出る
        for case let .send(b) in phone.start() { return b }
        return []
    }

    /// 1 バイトだけ書く相手が 8 つ来ても、枠を使わない。
    func testOneByteStrangersDoNotTakeSlots() {
        let mac = MacBrain(store: MemoryTrustStore(), now: { 1000 })
        mac.openPairing()
        for i in 0..<MacBrain.maxPeers + 4 { _ = mac.receive(peer: "stranger\(i)", bytes: [0x00]) }
        let outs = mac.receive(peer: "realPhone", bytes: phoneHello())
        XCTAssertFalse(outs.isEmpty, "本物の iPhone に返事が返る")
    }

    /// 形の不正な挨拶・ペアリングの約束だけ送る相手も、枠を残さない。
    func testMalformedHelloAndCommitDoNotTakeSlots() {
        let mac = MacBrain(store: MemoryTrustStore(), now: { 1000 })
        mac.openPairing()
        for i in 0..<MacBrain.maxPeers + 4 {
            _ = mac.receive(peer: "bad\(i)", bytes: [WireKind.hello])
            _ = mac.receive(peer: "badc\(i)", bytes: [WireKind.pairCommit, 1])
        }
        XCTAssertFalse(mac.receive(peer: "realPhone", bytes: phoneHello()).isEmpty)
    }

    /// 既知の機器の挨拶だけ送って黙り込む相手（購読も切断通知もない）で枠が埋まっても、時間がたてば捨てられて本物の iPhone が入れる。
    func testSilentHellosAreDroppedAfterTheIdleLimit() {
        var t = 1000.0
        let store = MemoryTrustStore()
        let knownID = Array(repeating: UInt8(9), count: 8)
        store.save(deviceID: knownID, master: SystemRandom().bytes(32))
        let mac2 = MacBrain(store: store, now: { t })
        for i in 0..<MacBrain.maxPeers {
            _ = mac2.receive(peer: "ghost\(i)", bytes: [WireKind.hello] + knownID + SystemRandom().bytes(16))
        }
        let hello = [WireKind.hello] + knownID + SystemRandom().bytes(16)
        XCTAssertTrue(mac2.receive(peer: "realPhone", bytes: hello).isEmpty, "30 秒たつ前は枠がふさがっている")
        t += MacBrain.peerIdleLimit + 1
        XCTAssertFalse(mac2.receive(peer: "realPhone", bytes: hello).isEmpty, "30 秒たてば古い未認証の相手が捨てられて入れる")
    }

    /// 番号を打っている最中の窓の持ち主（公開まで進んだ相手）は、時間では捨てない。
    /// （約束だけ送って進まない持ち主は、別の検査 StalledOwnerTests で手放される）
    func testPairingOwnerWhoRevealedIsNotPurged() {
        var t = 1000.0
        let mac = MacBrain(store: MemoryTrustStore(), now: { t })
        mac.openPairing()
        let phone = PhoneBrain(deviceID: Array(repeating: 7, count: 8), record: nil)
        var toPhone: [[UInt8]] = []
        var toMac: [[UInt8]] = []
        for case let .send(b) in phone.start() { toMac.append(b) }
        while !toMac.isEmpty || !toPhone.isEmpty {
            if !toMac.isEmpty { for case let .send(_, b) in mac.receive(peer: "owner", bytes: toMac.removeFirst()) { toPhone.append(b) } }
            if !toPhone.isEmpty { for case let .send(b) in phone.receive(toPhone.removeFirst()) { toMac.append(b) } }
        }
        XCTAssertEqual(phone.state, .awaitingCode)
        t += MacBrain.peerIdleLimit + 5   // 窓（120 秒）の中で、番号を打つのに時間がかかっている
        _ = mac.tick()
        XCTAssertTrue(mac.pairingIsOpen)
        let commit = [WireKind.pairCommit] + Array(repeating: UInt8(1), count: 8) + SystemRandom().bytes(32)
        // 持ち主のままなので、別の機器は busy
        XCTAssertEqual(mac.receive(peer: "other", bytes: commit),
                       [.send(peer: "other", bytes: [WireKind.reject, RejectReason.busy.rawValue])])
    }
}
