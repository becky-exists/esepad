import XCTest
@testable import EsepadCore

final class FramingTests: XCTestCase {
    func testEncodeDecodeSplitAnywhere() {
        let a: [UInt8] = Array(1...30), b: [UInt8] = [9], c: [UInt8] = Array(repeating: 7, count: 200)
        let stream = [a, b, c].flatMap { FrameCodec.encode($0)! }
        // どこで区切って届いても、同じ 3 つが取り出せる
        for chunk in [1, 2, 3, 7, 31, 64, 500] {
            var buf = FrameBuffer()
            var out: [[UInt8]] = []
            var i = 0
            while i < stream.count {
                out += buf.append(Array(stream[i..<min(i + chunk, stream.count)]))
                i += chunk
            }
            XCTAssertEqual(out, [a, b, c], "chunk \(chunk)")
            XCTAssertFalse(buf.corrupt)
        }
    }

    func testRejectsBadLengthAndStopsAccepting() {
        var buf = FrameBuffer()
        XCTAssertTrue(buf.append([0, 0, 1, 2]).isEmpty)
        XCTAssertTrue(buf.corrupt)
        XCTAssertTrue(buf.append(FrameCodec.encode([1, 2, 3])!).isEmpty, "壊れたあとは受け付けない")
        var big = FrameBuffer()
        _ = big.append([0xFF, 0xFF])
        XCTAssertTrue(big.corrupt)
        XCTAssertNil(FrameCodec.encode([]))
        XCTAssertNil(FrameCodec.encode(Array(repeating: 0, count: FrameCodec.maxPayload + 1)))
    }
}

final class PingTests: XCTestCase {
    func testPingIsAnsweredByMacAndNotTreatedAsAnInput() {
        let l = HandshakeTests().pairedLink()
        let out = l.mac.receive(peer: "A", bytes: l.phone.seal(.ping(token: 0xCAFE))!)
        XCTAssertEqual(out.count, 1)
        guard case let .send(_, reply)? = out.first else { return XCTFail() }
        XCTAssertFalse(out.contains { if case .event = $0 { return true } else { return false } }, "操作としては出さない")
        let got = l.phone.receive(reply)
        XCTAssertEqual(got, [.pong(token: 0xCAFE)])
        // 続けて普通の操作も通る（カウンターが崩れない）
        l.applyMac(l.mac.receive(peer: "A", bytes: l.phone.seal(.click)!))
        XCTAssertEqual(l.events, [.click])
        let again = l.mac.receive(peer: "A", bytes: l.phone.seal(.ping(token: 2))!)
        guard case let .send(_, reply2)? = again.first else { return XCTFail() }
        XCTAssertEqual(l.phone.receive(reply2), [.pong(token: 2)])
    }

    func testForgedOrReplayedPongIsIgnored() {
        let l = HandshakeTests().pairedLink()
        guard case let .send(_, reply)? = l.mac.receive(peer: "A", bytes: l.phone.seal(.ping(token: 5))!).first else { return XCTFail() }
        XCTAssertEqual(l.phone.receive(reply), [.pong(token: 5)])
        XCTAssertTrue(l.phone.receive(reply).isEmpty, "同じものの再生は通らない")
        XCTAssertTrue(l.phone.receive([WireKind.macData] + SystemRandom().bytes(30)).isEmpty)
    }

    func testPingRoundTripEncoding() {
        XCTAssertEqual(PadEvent.decode(PadEvent.ping(token: 123456).encode()), .ping(token: 123456))
        XCTAssertNil(PadEvent.decode([8, 1, 2]))
    }
}

final class ScrollEmitterTests: XCTestCase {
    func testDirectionSign() {
        XCTAssertEqual(ScrollDirection.sign(systemNatural: true, reversed: false), 1)
        XCTAssertEqual(ScrollDirection.sign(systemNatural: false, reversed: false), -1)
        XCTAssertEqual(ScrollDirection.sign(systemNatural: true, reversed: true), -1)
        XCTAssertEqual(ScrollDirection.sign(systemNatural: false, reversed: true), 1)
    }

    func testFullSequenceOrder() {
        var e = ScrollEmitter()
        let begin = e.touchBegan(dx: 0, dy: 6)
        XCTAssertEqual(begin, [
            .gesture(phase: 128, dx: 0, dy: 0), .series(started: true),
            .gesture(phase: 1, dx: 0, dy: 6),
            .wheel(dx: 0, dy: 6, scrollPhase: 1, momentumPhase: 0),
        ])
        XCTAssertEqual(e.touchChanged(dx: 0, dy: 4), [
            .gesture(phase: 2, dx: 0, dy: 4), .wheel(dx: 0, dy: 4, scrollPhase: 2, momentumPhase: 0),
        ])
        XCTAssertEqual(e.touchEnded(), [
            .gesture(phase: 4, dx: 0, dy: 0), .series(started: false),
            .wheel(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0),
        ])
        XCTAssertEqual(e.momentum(dx: 0, dy: 9), [.wheel(dx: 0, dy: 9, scrollPhase: 0, momentumPhase: 1)])
        XCTAssertEqual(e.momentum(dx: 0, dy: 8), [.wheel(dx: 0, dy: 8, scrollPhase: 0, momentumPhase: 2)])
        XCTAssertEqual(e.momentumEnded(), [.wheel(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3)])
        XCTAssertTrue(e.momentumEnded().isEmpty, "始まっていなければ終わりも出さない")
    }

    func testSubpixelRemaindersAreCarriedSoNothingIsLost() {
        var e = ScrollEmitter()
        _ = e.touchBegan(dx: 0, dy: 0)
        var total = 0.0
        for _ in 0..<100 {
            for op in e.touchChanged(dx: 0, dy: 0.3) { if case let .wheel(_, dy, _, _) = op { total += dy } }
        }
        XCTAssertEqual(total, 30, accuracy: 1, "0.3 を 100 回 = 30 ピクセル（端数を持ち越す）")
    }

    func testChangedBeforeBeganOrAfterEndedEmitsNothing() {
        var e = ScrollEmitter()
        XCTAssertTrue(e.touchChanged(dx: 1, dy: 1).isEmpty)
        _ = e.touchBegan(dx: 0, dy: 1)
        _ = e.touchEnded()
        XCTAssertTrue(e.touchChanged(dx: 1, dy: 1).isEmpty)
        XCTAssertTrue(e.touchEnded().isEmpty)
    }

    func testCancelClosesTouchAndMomentum() {
        var e = ScrollEmitter()
        _ = e.touchBegan(dx: 0, dy: 1)
        let c = e.cancel()
        XCTAssertEqual(c.last, .wheel(dx: 0, dy: 0, scrollPhase: 8, momentumPhase: 0))
        XCTAssertFalse(e.isTouching)
        _ = e.momentum(dx: 0, dy: 3)
        XCTAssertEqual(e.cancel(), [.wheel(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3)])
        XCTAssertTrue(e.cancel().isEmpty)
    }

    func testTouchDuringMomentumCanRestart() {
        var e = ScrollEmitter()
        _ = e.touchBegan(dx: 0, dy: 1); _ = e.touchEnded(); _ = e.momentum(dx: 0, dy: 5)
        XCTAssertTrue(e.isMomentum)
        _ = e.momentumEnded()
        XCTAssertEqual(e.touchBegan(dx: 0, dy: 2).first, .gesture(phase: 128, dx: 0, dy: 0))
    }
}

final class DockSwipeTests: XCTestCase {
    private func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    func testFixed1616() {
        XCTAssertEqual(DockSwipe.fixed1616(1), 65536)
        XCTAssertEqual(DockSwipe.fixed1616(-1), -65536)
        XCTAssertEqual(DockSwipe.fixed1616(0), 0)
        XCTAssertEqual(DockSwipe.fixed1616(1e-9), 1, "0 でない値は 0 に潰さない")
        XCTAssertEqual(DockSwipe.fixed1616(-1e-9), -1)
        XCTAssertEqual(DockSwipe.fixed1616(9999), 9999 * 65536)
        XCTAssertEqual(DockSwipe.fixed1616(1e12), Int32(32767 * 65536), "大きすぎても溢れない")
    }

    func testPayloadLayoutWithoutVelocity() {
        let p = DockSwipe.ioHIDPayload(.init(phase: 1, motion: 1, progress: -1, posX: 0.1, timestamp: 0x1_0000_0002))
        XCTAssertEqual(p.count, 28 + 40)
        XCTAssertEqual(u32(p, 0), 2); XCTAssertEqual(u32(p, 4), 1, "時刻の上位")
        XCTAssertEqual(u32(p, 24), 1, "中身の数")
        XCTAssertEqual(u32(p, 28), 40, "ジェスチャーの大きさ")
        XCTAssertEqual(u32(p, 32), 23, "ジェスチャーの種類")
        XCTAssertEqual(u32(p, 36), 1 << 24, "段階")
        XCTAssertEqual(Int32(bitPattern: u32(p, 44)), DockSwipe.fixed1616(0.1))
        XCTAssertEqual(UInt16(p[60]) | UInt16(p[61]) << 8, 1, "横")
        XCTAssertEqual(UInt16(p[62]) | UInt16(p[63]) << 8, 3, "dock primary")
        XCTAssertEqual(Int32(bitPattern: u32(p, 64)), -65536, "進み具合")
    }

    func testEndedPhaseAddsVelocityEvent() {
        let p = DockSwipe.ioHIDPayload(.init(phase: 4, motion: 1, progress: -1, velX: -9999, timestamp: 1))
        XCTAssertEqual(p.count, 28 + 40 + 28)
        XCTAssertEqual(u32(p, 24), 2)
        XCTAssertEqual(u32(p, 68), 28)
        XCTAssertEqual(u32(p, 72), 9)
        XCTAssertEqual(p[80], 1, "depth")
        XCTAssertEqual(Int32(bitPattern: u32(p, 84)), DockSwipe.fixed1616(-9999))
    }

    func testAppendRawFieldFormat() {
        let base: [UInt8] = [0, 0, 0, 2, 9, 9, 9]
        let out = DockSwipe.appendRawField(to: base, payload: [1, 2, 3])!
        XCTAssertEqual(out, base + [0, 3, 0x10, 0x6D, 1, 2, 3], "長さ(2) + 4205 = 0x106D (2) + 中身、どれも上位から")
        XCTAssertNil(DockSwipe.appendRawField(to: [0, 0, 0, 1, 9], payload: [1]), "版が違えば作らない")
        XCTAssertNil(DockSwipe.appendRawField(to: [0, 0], payload: [1]))
    }

    func testHorizontalDirections() {
        let right = DockSwipe.horizontalPhases(toRight: true, timestamp: 1)
        XCTAssertEqual(right.map(\.phase), [1, 2, 4])
        XCTAssertTrue(right.allSatisfy { $0.progress == -1 && $0.motion == 1 })
        XCTAssertEqual(right.last?.velX, -9999)
        let left = DockSwipe.horizontalPhases(toRight: false, timestamp: 1)
        XCTAssertTrue(left.allSatisfy { $0.progress == 1 })
        XCTAssertEqual(left.last?.velX, 9999)
        XCTAssertTrue(DockSwipe.verticalPhases(up: true, timestamp: 1).allSatisfy { $0.motion == 2 })
    }
}

final class StreamLinkTests: XCTestCase {
    /// 同じ端末の中で、2 本の流れを使って向かい合わせにつなぐ
    private func makePair() -> (FramedStreamLink, FramedStreamLink) {
        var aIn: InputStream?, aOut: OutputStream?, bIn: InputStream?, bOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &bIn, outputStream: &aOut)  // A が書いて B が読む
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &aIn, outputStream: &bOut)  // B が書いて A が読む
        return (FramedStreamLink(input: aIn!, output: aOut!), FramedStreamLink(input: bIn!, output: bOut!))
    }

    func testFramesTravelBothWaysInOrder() {
        let (a, b) = makePair()
        var gotByB: [[UInt8]] = [], gotByA: [[UInt8]] = []
        let done = expectation(description: "届く")
        b.onFrame = { f in gotByB.append(f); if gotByB.count == 50 { b.send([9, 9]) } }
        a.onFrame = { f in gotByA.append(f); done.fulfill() }
        a.open(); b.open()
        for i in 0..<50 { XCTAssertTrue(a.send([UInt8(i), 1, 2, 3])) }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(gotByB.count, 50)
        XCTAssertEqual(gotByB.map { $0[0] }, (0..<50).map { UInt8($0) })
        XCTAssertEqual(gotByA, [[9, 9]])
        a.close(); b.close()
    }

    func testBackpressureReportsNotWritableThenRecovers() {
        let (a, b) = makePair()
        let drained = expectation(description: "また送れる")
        var received = 0
        a.onWritable = { drained.fulfill() }
        a.open()
        // 受け側を開かないうちに大量に送ると、溜まる
        var sent = 0
        while a.canWrite && sent < 5000 { _ = a.send(Array(repeating: 7, count: 100)); sent += 1 }
        XCTAssertFalse(a.canWrite, "詰まったら canWrite が false になる")
        b.onFrame = { _ in received += 1 }
        b.open()
        wait(for: [drained], timeout: 3)
        XCTAssertTrue(a.canWrite)
        a.close(); b.close()
    }

    func testCorruptStreamClosesTheLink() {
        var rIn: InputStream?, rOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64, inputStream: &rIn, outputStream: &rOut)
        var xIn: InputStream?, xOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64, inputStream: &xIn, outputStream: &xOut)
        let link = FramedStreamLink(input: rIn!, output: xOut!)
        let closed = expectation(description: "閉じる")
        link.onClose = { closed.fulfill() }
        link.open()
        rOut!.open()
        _ = rOut!.write([0, 0, 1], maxLength: 3)   // 長さ 0 は不正
        wait(for: [closed], timeout: 3)
        XCTAssertFalse(link.isOpen)
        XCTAssertFalse(link.send([1]))
    }
}
