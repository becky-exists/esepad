import Foundation

/// 長さつきのパケットを、バイトの流れ（L2CAP チャンネルなど）に載せて読み書きする。
/// 読み書きは main の run loop の上で行う。
public final class FramedStreamLink: NSObject, StreamDelegate {
    public var onFrame: (([UInt8]) -> Void)?
    public var onClose: (() -> Void)?
    /// 溜まっていた書き込みが減って、また送れるようになった
    public var onWritable: (() -> Void)?

    private let input: InputStream
    private let output: OutputStream
    private var frames = FrameBuffer()
    private var pending: [UInt8] = []
    private var closed = false
    private var opened = false

    /// 未送信がこれ未満なら、次を送ってよい。超えたら呼び出し側は溜める（移動は足し合わされる）
    public static let writableLimit = 256

    public init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
        super.init()
    }

    public func open() {
        guard !opened else { return }
        opened = true
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        if input.streamStatus == .notOpen { input.open() }
        if output.streamStatus == .notOpen { output.open() }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        input.delegate = nil
        output.delegate = nil
        input.close()
        output.close()
        input.remove(from: .main, forMode: .common)
        output.remove(from: .main, forMode: .common)
        pending.removeAll()
        onClose?()
    }

    public var isOpen: Bool { opened && !closed }
    public var canWrite: Bool { isOpen && pending.count < Self.writableLimit }
    public var pendingBytes: Int { pending.count }

    /// 送る。いま書けない分は溜めて、書けるようになった時に続きを送る。
    @discardableResult
    public func send(_ payload: [UInt8]) -> Bool {
        guard isOpen, let framed = FrameCodec.encode(payload) else { return false }
        // 長い間詰まっている相手には溜め続けない
        guard pending.count < 64 * 1024 else { return false }
        pending.append(contentsOf: framed)
        flush()
        return true
    }

    private func flush() {
        while !pending.isEmpty, output.hasSpaceAvailable {
            let n = pending.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { break }
            pending.removeFirst(n)
        }
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            var buf = [UInt8](repeating: 0, count: 1024)
            while input.hasBytesAvailable {
                let n = input.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                for f in frames.append(Array(buf[0..<n])) { onFrame?(f) }
                if frames.corrupt { close(); return }
            }
        case .hasSpaceAvailable:
            let before = pending.count
            flush()
            if before >= Self.writableLimit, pending.count < Self.writableLimit { onWritable?() }
        case .endEncountered, .errorOccurred:
            close()
        default:
            break
        }
    }
}
