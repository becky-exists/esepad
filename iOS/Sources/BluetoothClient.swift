import CoreBluetooth
import Foundation
import EsepadCore

/// iPhone 側の Bluetooth。esepad の Mac を探して、つないで、読み書きする。ネットには出ない。
final class BluetoothClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct FoundMac: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    var onPower: ((Bool) -> Void)?
    var onFound: (([FoundMac]) -> Void)?
    /// 通知の購読まで済んだ。ここから挨拶を始められる
    var onLinked: (() -> Void)?
    var onUnlinked: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onCanSend: (() -> Void)?
    /// L2CAP を使い始めた・やめた
    var onTransportChange: (() -> Void)?

    private var central: CBCentralManager!
    private var seen: [UUID: CBPeripheral] = [:]
    private var found: [UUID: FoundMac] = [:]
    private var target: (id: UUID?, name: String?)?
    private var current: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var psmChar: CBCharacteristic?
    /// Mac が置いている L2CAP の番号
    private(set) var psm: CBL2CAPPSM?
    private var link: FramedStreamLink?
    private var channel: CBL2CAPChannel?
    /// L2CAP を開こうとして、まだ結果が出ていない
    private(set) var openingL2CAP = false
    private(set) var l2capError: String?

    private let serviceID = CBUUID(string: EsepadBLE.service)
    private let txID = CBUUID(string: EsepadBLE.tx)
    private let rxID = CBUUID(string: EsepadBLE.rx)
    private let psmID = CBUUID(string: EsepadBLE.psm)

    private(set) var currentMac: FoundMac?

    func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    var usingL2CAP: Bool { link?.isOpen == true }

    var canSend: Bool {
        if let l = link, l.isOpen { return l.canWrite }
        return tx != nil && (current?.canSendWriteWithoutResponse ?? false)
    }

    /// L2CAP が開いていればそちらで、なければ GATT（write without response）で送る
    func write(_ data: Data) {
        if let l = link, l.isOpen {
            l.send([UInt8](data))
            return
        }
        guard let p = current, let c = tx else { return }
        p.writeValue(data, for: c, type: .withoutResponse)
    }

    /// L2CAP のチャンネルを開く（Mac が番号を置いている時だけ）
    func openL2CAP() {
        guard let p = current, let psm = psm, link == nil, !openingL2CAP else {
            if psm == nil { l2capError = "Mac が L2CAP を用意していません" }
            return
        }
        openingL2CAP = true
        l2capError = nil
        p.openL2CAPChannel(psm)
    }

    func closeL2CAP() {
        link?.close()
        openingL2CAP = false
    }

    /// 覚えている Mac に自動でつなぐ（つなぎ直しも）
    func connect(toID id: String?, name: String?) {
        target = (id.flatMap(UUID.init(uuidString:)), name)
        guard central?.state == .poweredOn else { return }
        if let id = target?.id, let p = central.retrievePeripherals(withIdentifiers: [id]).first { attach(p) }
        scan()
    }

    /// 一覧から選んだ Mac につなぐ（初めてのペアリング）
    func connect(to mac: FoundMac) {
        guard let p = seen[mac.id] else { return }
        target = (mac.id, mac.name)
        attach(p)
    }

    func forgetTarget() {
        target = nil
        if let p = current { central?.cancelPeripheralConnection(p) }
        current = nil
        tx = nil
        rx = nil
        psm = nil
        closeL2CAP()
        currentMac = nil
        found.removeAll()
        scan()
    }

    /// 今の接続を切って、つなぎ直す
    func reconnect() {
        if let p = current { central?.cancelPeripheralConnection(p) }
    }

    private func scan() {
        guard central?.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func attach(_ p: CBPeripheral) {
        guard current?.identifier != p.identifier || current?.state == .disconnected else { return }
        if let old = current, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
        current = p
        p.delegate = self
        // つなぎ待ちは時間切れにならない。Mac が近づけば、そこでつながる
        central.connect(p, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        onPower?(on)
        guard on else { return }
        scan()
        if let t = target { connect(toID: t.id?.uuidString, name: t.name) }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "Mac"
        seen[p.identifier] = p
        found[p.identifier] = FoundMac(id: p.identifier, name: name, rssi: rssi.intValue)
        onFound?(found.values.sorted { $0.rssi > $1.rssi })

        // 覚えている Mac なら、つなぐ（Mac のアドレスが変わっていても、名前で見つける。
        // 偽物だった場合は、このあとの認証で弾かれる）
        if let t = target, current?.state != .connected, current?.state != .connecting {
            if p.identifier == t.id || (t.name != nil && t.name == name) {
                target = (p.identifier, name)
                attach(p)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan()
        currentMac = found[p.identifier] ?? FoundMac(id: p.identifier, name: p.name ?? "Mac", rssi: 0)
        p.discoverServices([serviceID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == current?.identifier, target != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.target != nil else { return }
            c.connect(p, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == current?.identifier else { return }
        tx = nil
        rx = nil
        psm = nil
        closeL2CAP()
        onUnlinked?()
        if target != nil {
            c.connect(p, options: nil)
            scan()
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceID }) else { return }
        p.discoverCharacteristics([txID, rxID, psmID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == txID { tx = ch }
            if ch.uuid == rxID { rx = ch }
            if ch.uuid == psmID { psmChar = ch; p.readValue(for: ch) }
        }
        if let rx = rx, tx != nil { p.setNotifyValue(true, for: rx) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == rxID, ch.isNotifying, tx != nil { onLinked?() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == rxID, let v = ch.value { onData?(v) }
        if ch.uuid == psmID, let v = ch.value, v.count == 2 {
            psm = CBL2CAPPSM(v[v.startIndex]) | (CBL2CAPPSM(v[v.startIndex + 1]) << 8)
        }
    }

    func peripheral(_ p: CBPeripheral, didOpen ch: CBL2CAPChannel?, error: Error?) {
        openingL2CAP = false
        guard let ch = ch, error == nil else {
            l2capError = error.map { "開けませんでした（\($0.localizedDescription)）" } ?? "開けませんでした"
            onTransportChange?()
            return
        }
        let l = FramedStreamLink(input: ch.inputStream, output: ch.outputStream)
        l.onFrame = { [weak self] frame in self?.onData?(Data(frame)) }
        l.onWritable = { [weak self] in self?.onCanSend?() }
        l.onClose = { [weak self] in
            self?.link = nil
            self?.channel = nil
            self?.onTransportChange?()
        }
        link = l
        channel = ch   // 手放すと閉じてしまうので持っておく
        l.open()
        onTransportChange?()
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        onCanSend?()
    }
}
