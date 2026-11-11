import XCTest
@testable import EsepadCore

final class PadEventTests: XCTestCase {
    func testRoundTrip() {
        let events: [PadEvent] = [
            .move(dx: 3.5, dy: -2.25, dtMs: 8.3),
            .scroll(phase: .began, dx: 1, dy: 2),
            .scroll(phase: .changed, dx: -4, dy: 9.5),
            .scroll(phase: .ended, dx: 1200, dy: -800),
            .click, .rightClick, .dragBegin, .dragEnd,
            .swipe(.left), .swipe(.right), .swipe(.up),
        ]
        for e in events {
            let decoded = PadEvent.decode(e.encode())
            if case let .move(dx, dy, dt) = e, case let .move(dx2, dy2, dt2)? = decoded {
                XCTAssertEqual(dx, dx2); XCTAssertEqual(dy, dy2)
                XCTAssertEqual(dt, dt2, accuracy: 0.1)  // 0.1 ミリ秒単位に丸める
            } else {
                XCTAssertEqual(decoded, e)
            }
        }
    }

    func testRejectsNonFiniteAndHugeValues() {
        for bad: Float in [.nan, .infinity, -.infinity, 1e9] {
            var w = ByteWriter(1); w.f32(bad); w.f32(0); w.u16(80)
            XCTAssertNil(PadEvent.decode(w.bytes), "move \(bad)")
            var s = ByteWriter(2); s.u8(1); s.f32(0); s.f32(bad)
            XCTAssertNil(PadEvent.decode(s.bytes), "scroll \(bad)")
        }
    }

    func testRejectsMalformed() {
        XCTAssertNil(PadEvent.decode([]))
        XCTAssertNil(PadEvent.decode([99]))
        XCTAssertNil(PadEvent.decode([1, 0, 0]))           // 短すぎる
        XCTAssertNil(PadEvent.decode([3, 0]))               // 余り
        XCTAssertNil(PadEvent.decode([7, 9]))               // 知らない向き
        XCTAssertNil(PadEvent.decode([2, 7, 0, 0, 0, 0, 0, 0, 0, 0])) // 知らない段階
    }

    func testEndedVelocityMayExceedDeltaLimit() {
        // 離す直前の速さは pt/秒なので、移動量の上限より大きくてよい
        XCTAssertNotNil(PadEvent.decode(PadEvent.scroll(phase: .ended, dx: 9000, dy: 0).encode()))
        XCTAssertNil(PadEvent.decode(PadEvent.scroll(phase: .changed, dx: 9000, dy: 0).encode()))
    }

    func testQueueMergesMovesAndKeepsOrder() {
        var q = OutboundQueue()
        q.push(.move(dx: 1, dy: 2, dtMs: 8))
        q.push(.move(dx: 3, dy: 4, dtMs: 8))
        q.push(.click)
        q.push(.move(dx: 1, dy: 1, dtMs: 8))
        q.push(.scroll(phase: .changed, dx: 1, dy: 1))
        q.push(.scroll(phase: .changed, dx: 2, dy: 2))
        q.push(.scroll(phase: .ended, dx: 10, dy: 10))
        XCTAssertEqual(q.pop(), .move(dx: 4, dy: 6, dtMs: 16))
        XCTAssertEqual(q.pop(), .click)
        XCTAssertEqual(q.pop(), .move(dx: 1, dy: 1, dtMs: 8))
        XCTAssertEqual(q.pop(), .scroll(phase: .changed, dx: 3, dy: 3))
        XCTAssertEqual(q.pop(), .scroll(phase: .ended, dx: 10, dy: 10))
        XCTAssertNil(q.pop())
    }

    func testQueueNeverLosesMovementTotal() {
        var q = OutboundQueue()
        var total: Float = 0
        for _ in 0..<5000 { q.push(.move(dx: 1, dy: 0, dtMs: 1)); total += 1 }
        var got: Float = 0
        while let e = q.pop() { if case let .move(dx, _, _) = e { got += dx } }
        XCTAssertEqual(got, total)
    }

    func testQueueDoesNotMergeAcrossLimitSoMacAcceptsIt() {
        var q = OutboundQueue()
        q.push(.move(dx: 2500, dy: 0, dtMs: 1))
        q.push(.move(dx: 2500, dy: 0, dtMs: 1))
        XCTAssertEqual(q.count, 2)
    }
}

final class StorageTests: XCTestCase {
    func testHexRoundTrip() {
        let b: [UInt8] = [0, 1, 15, 16, 254, 255]
        XCTAssertEqual(Hex.decode(Hex.encode(b)), b)
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("zz"))
    }

    func testPhoneStateProducesRecordOnlyWhenPaired() {
        var s = PhoneState(deviceID: Hex.encode([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertNil(s.record)
        s.master = Hex.encode(Array(repeating: 9, count: 32))
        XCTAssertEqual(s.record, PairingRecord(deviceID: [1, 2, 3, 4, 5, 6, 7, 8], master: Array(repeating: 9, count: 32)))
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(PhoneState.self, from: data), s)
    }
}
