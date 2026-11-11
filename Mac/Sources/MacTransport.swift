import CoreBluetooth
import Foundation
import EsepadCore

/// Mac 側の Bluetooth。サービスを 1 つ広告して、iPhone の接続を待つ。ネットには出ない。
final class MacTransport: NSObject, CBPeripheralManagerDelegate {
    var onReceive: ((String, [UInt8]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onChange: (() -> Void)?

    private var manager: CBPeripheralManager!
    private var txChar: CBMutableCharacteristic?
    private var rxChar: CBMutableCharacteristic?
    private var serviceAdded = false
    private var centrals: [String: CBCentral] = [:]
    private var pending: [(peer: String, data: Data)] = []
    /// L2CAP チャンネル（iPhone が開いた時だけ）。開いていれば、返事もこちらで送る
    private var links: [String: FramedStreamLink] = [:]
    private var channels: [String: CBL2CAPChannel] = [:]
    private var psm: CBL2CAPPSM?
    /// 同時に開いておく L2CAP は 4 本まで（いちばん古いものから閉じる。閉じても GATT で続けられる）
    private var linkSlots = LinkSlots(capacity: 4)

    private let serviceID = CBUUID(string: EsepadBLE.service)
    private let txID = CBUUID(string: EsepadBLE.tx)
    private let rxID = CBUUID(string: EsepadBLE.rx)
    private let psmID = CBUUID(string: EsepadBLE.psm)

    private(set) var isPoweredOn = false
    private(set) var stateText = "Bluetooth を準備しています"

    /// Bluetooth の広告に載せる名前。Mac の名前は持ち主の名前入りのことが多く、近くの誰にでも見えてしまうので使わない。
    /// 意図的に単純化。固定の "esepad" にしている。上限=Mac が複数あると iPhone の一覧で名前では区別できない（電波の強さで選ぶ）、必要になったら窓が開いている間だけ名前を出す。
    let macName = "esepad"

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func send(peer: String, bytes: [UInt8]) {
        if let link = links[peer], link.send(bytes) { return }
        pending.append((peer, Data(bytes)))
        flush()
    }

    private func flush() {
        guard let rx = rxChar else { return }
        while let first = pending.first {
            guard let c = centrals[first.peer] else { pending.removeFirst(); continue }
            if first.data.count > c.maximumUpdateValueLength {
                NSLog("esepad: 送るデータ（\(first.data.count) バイト）が通信の上限（\(c.maximumUpdateValueLength) バイト）を超えています")
                pending.removeFirst()
                continue
            }
            if manager.updateValue(first.data, for: rx, onSubscribedCentrals: [c]) {
                pending.removeFirst()
            } else {
                return  // 詰まっている。peripheralManagerIsReady で続きを送る
            }
        }
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn:
            isPoweredOn = true
            stateText = "つなぐ iPhone を待っています"
            if !serviceAdded {
                serviceAdded = true
                // L2CAP の受け口を先に作り、番号（PSM）が決まってからサービスを追加する
                p.publishL2CAPChannel(withEncryption: false)
            }
        case .unauthorized:
            isPoweredOn = false
            stateText = "Bluetooth の許可がありません（システム設定 > プライバシーとセキュリティ）"
        case .poweredOff:
            isPoweredOn = false
            stateText = "Bluetooth がオフです"
            centrals.removeAll()
            links.values.forEach { $0.close() }
            serviceAdded = false   // オンに戻ったら、サービスを作り直す
            psm = nil
        default:
            isPoweredOn = false
            stateText = "Bluetooth を使えません"
        }
        onChange?()
    }

    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error = error {
            NSLog("esepad: L2CAP を公開できません（GATT だけで続けます）: \(error)")
        } else {
            psm = PSM
        }
        addService()
    }

    private func addService() {
        // 書き込みだけで応答なし（遅れを小さくするため）。暗号化と認証はアプリの中で行う
        let tx = CBMutableCharacteristic(type: txID, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        let rx = CBMutableCharacteristic(type: rxID, properties: [.notify], value: nil, permissions: [.readable])
        var chars: [CBMutableCharacteristic] = [tx, rx]
        if let psm = psm {
            var le = psm.littleEndian
            let value = Data(bytes: &le, count: MemoryLayout<UInt16>.size)
            chars.append(CBMutableCharacteristic(type: psmID, properties: [.read], value: value, permissions: [.readable]))
        }
        let svc = CBMutableService(type: serviceID, primary: true)
        svc.characteristics = chars
        txChar = tx
        rxChar = rx
        manager.add(svc)
    }

    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let ch = channel, error == nil else { return }
        let key = ch.peer.identifier.uuidString
        links[key]?.close()
        for old in linkSlots.admit(key) where old != key {
            links[old]?.close()
            links.removeValue(forKey: old)
            channels.removeValue(forKey: old)
        }
        let link = FramedStreamLink(input: ch.inputStream, output: ch.outputStream)
        link.onFrame = { [weak self] bytes in self?.onReceive?(key, bytes) }
        link.onClose = { [weak self] in
            self?.links.removeValue(forKey: key)
            self?.channels.removeValue(forKey: key)
            self?.linkSlots.remove(key)
        }
        links[key] = link
        channels[key] = ch   // チャンネルを手放すと閉じてしまうので持っておく
        link.open()
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            NSLog("esepad: サービスを追加できません: \(error)")
            return
        }
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID],
                            CBAdvertisementDataLocalNameKey: macName])
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        centrals[central.identifier.uuidString] = central
        // 接続の間隔をいちばん短く頼む（指とカーソルの遅れを小さくするため）
        p.setDesiredConnectionLatency(.low, for: central)
        onChange?()
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        let key = central.identifier.uuidString
        centrals.removeValue(forKey: key)
        links[key]?.close()
        pending.removeAll { $0.peer == key }
        onDisconnect?(key)
        onChange?()
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) {
        flush()
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == txID {
            guard let v = r.value else { continue }
            onReceive?(r.central.identifier.uuidString, [UInt8](v))
        }
    }
}
