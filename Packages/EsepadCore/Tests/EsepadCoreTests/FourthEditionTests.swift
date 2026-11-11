import XCTest
@testable import EsepadCore

/// 4 版目: 面の色の着せ替え、Mac が教える自分のこと
final class SurfaceColorTests: XCTestCase {
    func testExactlyFourColorsAndNoBlack() {
        XCTAssertEqual(SurfaceColor.allCases, [.silver, .starlight, .spaceGray, .midnight])
        XCTAssertEqual(SurfaceColor.silver.rgb, 0xE3E4E6)
        XCTAssertEqual(SurfaceColor.starlight.rgb, 0xEFE6D8)
        XCTAssertEqual(SurfaceColor.spaceGray.rgb, 0x6E6F73)
        XCTAssertEqual(SurfaceColor.midnight.rgb, 0x2E3643)
        XCTAssertEqual(SurfaceColor.allCases.map(\.displayName), ["シルバー", "スターライト", "スペースグレイ", "ミッドナイト"])
        XCTAssertEqual(SurfaceColor.fallback, .spaceGray)
    }

    func testInkFollowsBrightnessOfTheSurfaceAndIsReadable() {
        XCTAssertTrue(SurfaceColor.silver.inkIsDark)
        XCTAssertTrue(SurfaceColor.starlight.inkIsDark)
        XCTAssertFalse(SurfaceColor.spaceGray.inkIsDark)
        XCTAssertFalse(SurfaceColor.midnight.inkIsDark)
        for c in SurfaceColor.allCases {
            let l = c.luminance
            let ratio = c.inkIsDark ? (l + 0.05) / 0.05 : 1.05 / (l + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(c) の上の文字は 4.5:1 以上")
        }
    }
}

final class SurfaceInkTests: XCTestCase {
    func testSecondaryTextIsReadableOnEveryColor() {
        for c in SurfaceColor.allCases {
            let a = c.inkOpacity(preferring: 0.6)
            XCTAssertGreaterThanOrEqual(c.contrast(inkOpacity: a), 4.5, "\(c) の補助文字")
            XCTAssertGreaterThanOrEqual(a, 0.6)
            XCTAssertLessThanOrEqual(a, 1)
        }
        // 明るい面と暗い面は薄いままでよい。中間のスペースグレイだけ濃くなる
        XCTAssertEqual(SurfaceColor.midnight.inkOpacity(preferring: 0.6), 0.6, accuracy: 1e-9)
        XCTAssertEqual(SurfaceColor.silver.inkOpacity(preferring: 0.6), 0.6, accuracy: 1e-9)
        XCTAssertGreaterThan(SurfaceColor.spaceGray.inkOpacity(preferring: 0.6), 0.8)
    }

    func testFullInkIsAlwaysReadable() {
        for c in SurfaceColor.allCases { XCTAssertGreaterThanOrEqual(c.contrast(inkOpacity: 1), 4.5) }
    }
}

final class MacInfoTests: XCTestCase {
    let mbp = MacInfo(model: "MacBookPro18,4", housing: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])

    func testRoundTrip() {
        XCTAssertEqual(MacInfo.decode(mbp.encode()), mbp)
        let none = MacInfo(model: "Mac16,10", housing: [])
        XCTAssertEqual(MacInfo.decode(none.encode()), none)
    }

    func testRejectsMalformed() {
        XCTAssertNil(MacInfo.decode([]))
        XCTAssertNil(MacInfo.decode([1, 0, 0]), "種類が違う")
        XCTAssertNil(MacInfo.decode(Array(mbp.encode().dropLast())), "短い")
        XCTAssertNil(MacInfo.decode(mbp.encode() + [0]), "余り")
        XCTAssertNil(MacInfo.decode([2, 200] + [UInt8](repeating: 65, count: 200) + [0]), "長すぎる機種名")
        XCTAssertNil(MacInfo.decode([2, 2, 0xFF, 0xFE, 0]), "文字として読めない")
        XCTAssertNil(MacInfo.decode([2, 0, 40] + [UInt8](repeating: 0, count: 40)), "長すぎる色")
    }

    func testEncodeTruncatesInsteadOfOverflowing() {
        let long = MacInfo(model: String(repeating: "M", count: 100), housing: [UInt8](repeating: 9, count: 100))
        let d = MacInfo.decode(long.encode())
        XCTAssertEqual(d?.model.count, 32)
        XCTAssertEqual(d?.housing.count, 32)
    }

    func testOnlyAVerifiedPairIsAutomatic() {
        XCTAssertEqual(mbp.autoColor, .silver)
        var other = mbp
        other.housing[0] = 2
        XCTAssertNil(other.autoColor, "知らない値は当てない")
        XCTAssertNil(MacInfo(model: "MacBookPro18,3", housing: mbp.housing).autoColor, "機種が違えば当てない")
        XCTAssertNil(MacInfo(model: "MacBookPro18,4", housing: []).autoColor)
        XCTAssertNil(MacInfo(model: "Mac16,10", housing: []).autoColor)
    }
}

final class SurfaceColorBookTests: XCTestCase {
    let mbp = MacInfo(model: "MacBookPro18,4", housing: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])

    func testNewMacStartsAtSpaceGrayEvenIfAnotherColorWasUsedBefore() {
        var b = SurfaceColorBook()
        b.choose(.midnight, for: "mac-A")
        XCTAssertEqual(b.color(for: "mac-B"), .spaceGray, "別の Mac の色を引き継がない")
        XCTAssertEqual(b.color(for: "mac-A"), .midnight)
    }

    func testBeforeAMacIsKnownUsesTheLastColor() {
        var b = SurfaceColorBook()
        XCTAssertEqual(b.color(for: nil), .spaceGray)
        b.choose(.starlight, for: nil)
        XCTAssertEqual(b.color(for: nil), .starlight)
    }

    func testLearnsFromATableHitAndOnlyThen() {
        var b = SurfaceColorBook()
        XCTAssertTrue(b.learn(mbp, for: "mbp"))
        XCTAssertEqual(b.color(for: "mbp"), .silver)
        XCTAssertFalse(b.learn(MacInfo(model: "Mac16,10", housing: []), for: "mini"), "表に無ければ何も変えない")
        XCTAssertEqual(b.color(for: "mini"), .spaceGray)
        XCTAssertFalse(b.learn(mbp, for: nil), "Mac が決まっていなければ覚えない")
    }

    func testChosenColorBeatsTheAutomaticOne() {
        var b = SurfaceColorBook()
        b.choose(.midnight, for: "mbp")
        XCTAssertFalse(b.learn(mbp, for: "mbp"), "見た目は変わらない")
        XCTAssertEqual(b.color(for: "mbp"), .midnight)
        b.choose(.silver, for: "mbp")
        XCTAssertEqual(b.color(for: "mbp"), .silver)
    }

    func testLearningTwiceDoesNotReportAChange() {
        var b = SurfaceColorBook()
        XCTAssertTrue(b.learn(mbp, for: "mbp"))
        XCTAssertFalse(b.learn(mbp, for: "mbp"))
    }

    func testForgetAndPersist() throws {
        var b = SurfaceColorBook()
        b.choose(.midnight, for: "A")
        _ = b.learn(mbp, for: "B")
        let d = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(SurfaceColorBook.self, from: d)
        XCTAssertEqual(back, b)
        b.forget("A")
        XCTAssertEqual(b.color(for: "A"), .spaceGray)
        XCTAssertEqual(b.color(for: "B"), .silver)
    }

    func testOldSavedDataFailsSoftly() {
        XCTAssertNil(try? JSONDecoder().decode(SurfaceColorBook.self, from: Data("{\"chosen\":{\"a\":\"pink\"}}".utf8)),
                     "知らない色が入っていたら読めない（呼ぶ側が空から始める）")
    }
}

final class MacInfoWireTests: XCTestCase {
    func testPhoneLearnsMacInfoRightAfterReady() {
        let l = HandshakeTests().pairedLink()
        // もう一度つなぎ直して、Mac が教える流れを見る
        l.mac.macInfo = MacInfo(model: "MacBookPro18,4", housing: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])
        l.phoneOutputs.removeAll()
        l.mac.peerDisconnected("A")
        l.phone.disconnected()
        l.applyPhone(l.phone.start())
        l.pump()
        XCTAssertEqual(l.phone.state, .ready)
        let infos = l.phoneOutputs.compactMap { o -> MacInfo? in if case let .macInfo(i) = o { return i } else { return nil } }
        XCTAssertEqual(infos, [l.mac.macInfo!])
        XCTAssertEqual(infos.first?.autoColor, .silver)
        // 知らせのあとも、操作と往復の確かめは使える（カウンターが続いている）
        l.applyMac(l.mac.receive(peer: "A", bytes: l.phone.seal(.click)!))
        XCTAssertEqual(l.events.last, .click)
        l.applyMac(l.mac.receive(peer: "A", bytes: l.phone.seal(.ping(token: 77))!))
        l.pump()
        XCTAssertTrue(l.phoneOutputs.contains(.pong(token: 77)))
    }

    func testNothingIsSentWhenMacInfoIsUnset() {
        let l = HandshakeTests().pairedLink()
        XCTAssertFalse(l.phoneOutputs.contains { if case .macInfo = $0 { return true } else { return false } })
    }

    func testTamperedInfoIsDropped() {
        let l = Link()
        l.mac.macInfo = MacInfo(model: "MacBookPro18,4", housing: [1])
        l.mac.openPairing()
        l.applyPhone(l.phone.start())
        l.pump()
        l.applyPhone(l.phone.submitCode(l.macCode!))
        l.pump()
        l.approve()
        l.phoneOutputs.removeAll()
        l.mac.peerDisconnected("A")
        l.phone.disconnected()
        var count = 0
        l.tamperToPhone = { b in count += 1; var c = b; if count == 3 { c[c.count - 1] ^= 1 }; return c }
        l.applyPhone(l.phone.start())
        l.pump()
        XCTAssertFalse(l.phoneOutputs.contains { if case .macInfo = $0 { return true } else { return false } })
        XCTAssertEqual(l.phone.state, .ready, "知らせが壊れても、つながりは続く")
    }
}
