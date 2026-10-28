import CoreBluetooth
import Foundation
import Observation
import OuraProtocol

@MainActor
@Observable
final class RingTransport: NSObject {
  struct NearbyRing: Identifiable {
    let id: UUID
    let name: String
    let signal: Int
  }

  enum Failure: LocalizedError {
    case bluetoothUnavailable, disconnected, timeout, busy, missingCharacteristics
    var errorDescription: String? {
      switch self {
      case .bluetoothUnavailable:
        "Bluetooth is unavailable. Check Bluetooth permission and turn Bluetooth on."
      case .disconnected: "The ring disconnected. Move it closer and try again."
      case .timeout:
        "The ring did not respond in time. Keep it nearby and on its charger during setup."
      case .busy: "A ring operation is already running."
      case .missingCharacteristics: "This device does not expose the expected Oura ring service."
      }
    }
  }

  private(set) var nearby: [NearbyRing] = []
  private(set) var isScanning = false
  private(set) var scanFinished = false
  private(set) var connectedID: UUID?
  private(set) var status = "Not connected"
  var onRestoredConnection: (() -> Void)?
  var onHistoryAvailable: (() -> Void)?
  var onLiveHeartRate: (([LiveHeartRateReading]) -> Void)?
  @ObservationIgnored private var reconnectID: UUID?
  @ObservationIgnored private var closingLink = false

  @ObservationIgnored private var central: CBCentralManager!
  @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
  @ObservationIgnored private var peripheral: CBPeripheral?
  @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
  @ObservationIgnored private var connection: CheckedContinuation<Void, Error>?
  @ObservationIgnored private var response: CheckedContinuation<[Packet], Error>?
  @ObservationIgnored private var operationID: UUID?
  @ObservationIgnored private var completion: ((Packet) -> Bool)?
  @ObservationIgnored private var packets: [Packet] = []
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?
  @ObservationIgnored private var scanTimeout: Task<Void, Never>?
  @ObservationIgnored private var restoring = false

  override init() {
    super.init()
    central = CBCentralManager(
      delegate: self, queue: .main,
      options: [
        CBCentralManagerOptionRestoreIdentifierKey: "app.ourasync.central",
        CBCentralManagerOptionShowPowerAlertKey: true,
      ])
  }

  func scan() throws {
    guard central.state == .poweredOn else { throw Failure.bluetoothUnavailable }
    nearby = []
    scanFinished = false
    isScanning = true
    status = "Looking for your ring"
    central.scanForPeripherals(withServices: [CBUUID(string: Commands.service)])
    scanTimeout?.cancel()
    scanTimeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      self?.stopScanning()
      self?.scanFinished = true
    }
  }

  func stopScanning() {
    central.stopScan()
    scanTimeout?.cancel()
    scanTimeout = nil
    isScanning = false
  }

  func connect(to id: UUID) async throws {
    try Task.checkCancellation()
    guard connection == nil, response == nil, !closingLink else { throw Failure.busy }
    guard central.state == .poweredOn else { throw Failure.bluetoothUnavailable }
    guard let ring = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
    else {
      throw Failure.disconnected
    }
    stopScanning()
    if let previous = peripheral, previous.identifier != id {
      central.cancelPeripheralConnection(previous)
    }
    peripheral = ring
    ring.delegate = self
    writeCharacteristic = nil
    connectedID = nil
    status = "Connecting"
    let operationID = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        self.operationID = operationID
        connection = continuation
        armTimeout(seconds: 45)
        if ring.state == .connected {
          ring.discoverServices([CBUUID(string: Commands.service)])
        } else {
          central.connect(ring)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelOperation(operationID) }
    }
  }

  func request(_ packet: Packet, until terminal: @escaping (Packet) -> Bool) async throws
    -> [Packet]
  {
    try Task.checkCancellation()
    guard response == nil, connection == nil, !closingLink else { throw Failure.busy }
    guard let peripheral, peripheral.state == .connected, let writeCharacteristic,
      connectedID != nil
    else { throw Failure.disconnected }
    let bytes = try packet.encoded()
    let operationID = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.operationID = operationID
        response = continuation
        completion = terminal
        packets = []
        armTimeout(seconds: 20)
        peripheral.writeValue(bytes, for: writeCharacteristic, type: .withResponse)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelOperation(operationID) }
    }
  }

  private func cancelOperation(_ id: UUID) {
    guard operationID == id else { return }
    if let peripheral {
      failLink(CancellationError(), peripheral: peripheral)
    } else {
      fail(CancellationError())
    }
  }

  func disconnect() {
    reconnectID = nil
    if let peripheral {
      failLink(Failure.disconnected, peripheral: peripheral)
    } else {
      fail(Failure.disconnected)
    }
  }

  func maintainConnection(to id: UUID, delay: TimeInterval = 0) {
    reconnectID = id
    guard central.state == .poweredOn, !closingLink else { return }
    guard let ring = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
    else { return }
    if ring.state == .disconnected {
      peripheral = ring
      ring.delegate = self
      restoring = true
      // Let CoreBluetooth own the delay so recovery does not depend on an app timer
      // continuing to execute while iOS has suspended us.
      let options: [String: Any]? =
        delay > 0 ? [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: delay)] : nil
      central.connect(ring, options: options)
    }
  }

  private func armTimeout(seconds: UInt64) {
    timeoutTask?.cancel()
    timeoutTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      guard let self else { return }
      // Close the link so a late response cannot be mistaken for the next request.
      if let ring = self.peripheral {
        self.failLink(Failure.timeout, peripheral: ring)
      } else {
        self.fail(Failure.timeout)
      }
    }
  }

  private func failLink(_ error: Error, peripheral: CBPeripheral, source: String = #function) {
    closingLink = peripheral.state != .disconnected
    fail(error, source: source)
    // Clearing local state alone leaves a connected but unusable link. Closing
    // it lets the existing disconnect callback resume automatic reconnection.
    central.cancelPeripheralConnection(peripheral)
  }

  private func fail(_ error: Error, source: String = #function) {
    let failure = error as NSError
    // A later disconnect callback must not overwrite the failed operation's cause.
    if connection != nil || response != nil {
      UserDefaults.standard.set(
        [
          "date": Date(), "source": source, "domain": failure.domain,
          "code": failure.code, "message": failure.localizedDescription,
          "hadPendingConnection": connection != nil, "hadPendingRequest": response != nil,
        ], forKey: "ring.lastBluetoothFailure")
    }
    #if DEBUG
      print(
        "Bluetooth failure: \(failure.domain) (\(failure.code)): \(failure.localizedDescription)")
    #endif
    timeoutTask?.cancel()
    timeoutTask = nil
    let pendingConnection = connection
    let pendingResponse = response
    connection = nil
    response = nil
    operationID = nil
    completion = nil
    packets = []
    connectedID = nil
    writeCharacteristic = nil
    status = error.localizedDescription
    pendingConnection?.resume(throwing: error)
    pendingResponse?.resume(throwing: error)
  }
}

extension RingTransport: @preconcurrency CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .poweredOn {
      isScanning = false
      closingLink = false
      fail(Failure.bluetoothUnavailable)
    } else {
      status = "Bluetooth ready"
      if let reconnectID { maintainConnection(to: reconnectID) }
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi signal: NSNumber
  ) {
    peripherals[peripheral.identifier] = peripheral
    let name =
      advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
      ?? "Oura ring"
    let ring = NearbyRing(id: peripheral.identifier, name: name, signal: signal.intValue)
    if let index = nearby.firstIndex(where: { $0.id == ring.id }) {
      nearby[index] = ring
    } else {
      nearby.append(ring)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral.identifier == self.peripheral?.identifier, !closingLink else { return }
    peripheral.delegate = self
    peripheral.discoverServices([CBUUID(string: Commands.service)])
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    guard peripheral.identifier == self.peripheral?.identifier else { return }
    closingLink = false
    fail(error ?? Failure.disconnected)
    if let reconnectID { maintainConnection(to: reconnectID, delay: 5) }
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    guard peripheral.identifier == self.peripheral?.identifier else { return }
    closingLink = false
    fail(error ?? Failure.disconnected)
    if let reconnectID { maintainConnection(to: reconnectID, delay: 5) }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard
      let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
    else { return }
    peripheral = restored
    peripherals[restored.identifier] = restored
    restored.delegate = self
    restoring = true
    if restored.state == .connected {
      restored.discoverServices([CBUUID(string: Commands.service)])
    }
  }
}

extension RingTransport: @preconcurrency CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peripheral.identifier == self.peripheral?.identifier, !closingLink else { return }
    if let error {
      failLink(error, peripheral: peripheral)
      return
    }
    guard
      let service = peripheral.services?.first(where: {
        $0.uuid == CBUUID(string: Commands.service)
      })
    else {
      failLink(Failure.missingCharacteristics, peripheral: peripheral)
      return
    }
    peripheral.discoverCharacteristics(
      [
        CBUUID(string: Commands.writeCharacteristic), CBUUID(string: Commands.notifyCharacteristic),
      ], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard peripheral.identifier == self.peripheral?.identifier, !closingLink else { return }
    if let error {
      failLink(error, peripheral: peripheral)
      return
    }
    writeCharacteristic = service.characteristics?.first {
      $0.uuid == CBUUID(string: Commands.writeCharacteristic)
    }
    guard writeCharacteristic != nil,
      let notify = service.characteristics?.first(where: {
        $0.uuid == CBUUID(string: Commands.notifyCharacteristic)
      })
    else {
      failLink(Failure.missingCharacteristics, peripheral: peripheral)
      return
    }
    peripheral.setNotifyValue(true, for: notify)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard peripheral.identifier == self.peripheral?.identifier, !closingLink else { return }
    if let error {
      failLink(error, peripheral: peripheral)
      return
    }
    guard characteristic.uuid == CBUUID(string: Commands.notifyCharacteristic),
      characteristic.isNotifying
    else { return }
    connectedID = peripheral.identifier
    status = "Connected"
    let pending = connection
    connection = nil
    if pending != nil {
      timeoutTask?.cancel()
      timeoutTask = nil
      operationID = nil
    }
    pending?.resume()
    if restoring {
      restoring = false
      onRestoredConnection?()
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard peripheral.identifier == self.peripheral?.identifier, !closingLink else { return }
    if let error { failLink(error, peripheral: peripheral) }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard peripheral.identifier == self.peripheral?.identifier, !closingLink else { return }
    if let error {
      failLink(error, peripheral: peripheral)
      return
    }
    guard characteristic.uuid == CBUUID(string: Commands.notifyCharacteristic),
      let data = characteristic.value
    else { return }
    do {
      let notification = try RingNotification(data: data)
      if notification.historyAvailable { onHistoryAvailable?() }
      if !notification.liveHeartRate.isEmpty { onLiveHeartRate?(notification.liveHeartRate) }
      guard response != nil else { return }
      let incoming = notification.replies
      packets.append(contentsOf: incoming)
      if incoming.contains(where: { completion?($0) == true }) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = response
        let result = packets
        response = nil
        operationID = nil
        completion = nil
        packets = []
        pending?.resume(returning: result)
      }
    } catch {
      failLink(error, peripheral: peripheral)
    }
  }
}

extension RingTransport: RingConnection {
  func exchange(_ packet: Packet, reply: Reply) async throws -> [Packet] {
    try await request(packet) { reply.matches($0) || ($0.tag == 0x2f && $0.payload.first == 0x2f) }
  }
}
