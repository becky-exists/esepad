import XCTest
@testable import EsepadCore

#if canImport(Security)
/// キーチェーンの代わりに、読む・書くの結果を好きに返せる入れ物。
final class FakeBlob: BlobStore {
    var data: Data?
    var readFails = false
    var writeFails = false
    var writes = 0
    func read() -> BlobRead {
        if readFails { return .failed(-25308) }   // errSecInteractionNotAllowed（ロック中など）
        return data.map { .found($0) } ?? .notFound
    }
    func write(_ d: Data) -> Bool {
        writes += 1
        if writeFails { return false }
        data = d
        return true
    }
    func delete() { data = nil }
}

/// 読めなかった時に空から始めて元の鍵を消さないこと、保存の失敗を失敗として返すことの検査。
final class KeychainStoreTests: XCTestCase {
    private let id = Array(repeating: UInt8(7), count: 8)
    private let other = Array(repeating: UInt8(9), count: 8)

    private func seeded() -> FakeBlob {
        let b = FakeBlob()
        let seed = KeychainTrustStore(blob: b)
        XCTAssertTrue(seed.save(deviceID: id, master: Array(repeating: 1, count: 32)))
        b.writes = 0
        return b
    }

    /// 読めなかった（ロック中など）なら、保存しても元の一覧を消さない。読めるようになったら元の鍵が生きている。
    func testUnreadableKeychainIsNotOverwrittenByASave() {
        let b = seeded()
        b.readFails = true
        let store = KeychainTrustStore(blob: b)

        XCTAssertFalse(store.save(deviceID: other, master: Array(repeating: 2, count: 32)), "読めない間は保存しない")
        XCTAssertEqual(b.writes, 0, "元のデータに書き込んでいない")
        XCTAssertNil(store.master(for: id))

        b.readFails = false   // 読めるようになった
        XCTAssertEqual(store.master(for: id), Array(repeating: 1, count: 32), "元の鍵が残っている")
        XCTAssertTrue(store.save(deviceID: other, master: Array(repeating: 2, count: 32)))
        XCTAssertEqual(store.count, 2)
    }

    /// 保存の形式が読めない（壊れた・形式が変わった）時も、上書きしない。
    func testUndecodableDataIsNotOverwritten() {
        let b = FakeBlob()
        b.data = Data("not json".utf8)
        let store = KeychainTrustStore(blob: b)

        XCTAssertFalse(store.save(deviceID: id, master: Array(repeating: 1, count: 32)))
        XCTAssertEqual(b.data, Data("not json".utf8))
    }

    /// 書けなかったら false を返し、覚えたことにしない。
    func testFailedWriteIsReportedAndNotRemembered() {
        let b = FakeBlob()
        b.writeFails = true
        let store = KeychainTrustStore(blob: b)

        XCTAssertFalse(store.save(deviceID: id, master: Array(repeating: 1, count: 32)))
        XCTAssertNil(store.master(for: id))
        XCTAssertEqual(store.count, 0)
    }

    /// 本当に何も無い（初めて）なら、普通に始められる。
    func testEmptyKeychainStartsFresh() {
        let store = KeychainTrustStore(blob: FakeBlob())
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.save(deviceID: id, master: Array(repeating: 1, count: 32)))
        XCTAssertEqual(store.count, 1)
    }

    /// iPhone: 読めなかった時、新しい ID を作って元の状態（マスター）を消さない。
    func testPhoneKeychainDoesNotReplaceAnUnreadableState() throws {
        let b = FakeBlob()
        let first = PhoneKeychain(blob: b)
        var s = first.load(random: SystemRandom())
        s.master = Hex.encode(Array(repeating: 3, count: 32))
        XCTAssertTrue(first.save(s))
        let original = b.data

        b.readFails = true
        let second = PhoneKeychain(blob: b)
        let temp = second.load(random: SystemRandom())
        XCTAssertNotEqual(temp.deviceID, s.deviceID, "仮の状態（保存しない）")
        XCTAssertFalse(second.save(temp), "読めていない間は保存しない")
        XCTAssertEqual(b.data, original, "元の状態が残っている")
    }

    /// iPhone: 初めてなら ID を作って保存する。保存に失敗したら save が false を返す。
    func testPhoneKeychainFirstRunAndFailedSave() {
        let b = FakeBlob()
        let k = PhoneKeychain(blob: b)
        let s = k.load(random: SystemRandom())
        XCTAssertNotNil(b.data, "初めての ID を保存した")
        b.writeFails = true
        XCTAssertFalse(k.save(s))
    }
}
#endif
