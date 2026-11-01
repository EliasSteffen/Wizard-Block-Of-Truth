import Foundation

/// How a mock transport hands events to its owner.
public enum MockDelivery: Sendable, Equatable {
  /// Synchronously, inside the call that caused the event.
  case immediate
  /// On a later main-queue turn (like a real network); chunks of one frame arrive in separate turns.
  case mainQueue
}

/// In-memory host transport for tests and previews.
///
/// Frames really go through `FrameCodec`/`FrameDecoder` (optionally split into chunks), so framing and ordering
/// bugs show up in tests. Not thread-safe: use it from the main thread only (hence `@unchecked Sendable`).
public final class MockHostTransport: HostSessionTransport, @unchecked Sendable {
  public var onEvent: (@Sendable (HostTransportEvent) -> Void)?
  public var delivery: MockDelivery = .immediate
  /// When set, every frame sent to a guest is split into chunks of at most this many bytes.
  public var chunkSize: Int?

  public private(set) var isRunning = false
  public private(set) var listenerRestartCount = 0
  /// Connections this side closed (`close(connectionID:)` or `stop()`), in order.
  public private(set) var closedConnectionIDs: [UUID] = []
  /// Every envelope sent to a guest, in send order.
  public private(set) var sentLog: [(connectionID: UUID, envelope: WireEnvelope)] = []

  private var guests: [UUID: MockGuestTransport] = [:]
  private var decoders: [UUID: FrameDecoder] = [:]

  public init() {}

  public var connectedGuestIDs: [UUID] { Array(guests.keys) }

  public func envelopesSent(to connectionID: UUID) -> [WireEnvelope] {
    sentLog.filter { $0.connectionID == connectionID }.map(\.envelope)
  }

  public func start() throws {
    isRunning = true
    emit(.listenerStateChanged(.ready))
  }

  public func restartListener() {
    listenerRestartCount += 1
    isRunning = true
    emit(.listenerStateChanged(.ready))
  }

  public func stop() {
    isRunning = false
    for id in Array(guests.keys) {
      close(connectionID: id)
    }
    emit(.listenerStateChanged(.stopped))
  }

  public func send(_ envelope: WireEnvelope, to connectionIDs: [UUID]) throws {
    let frame = try FrameCodec.encode(envelope)
    for id in connectionIDs {
      guard let guest = guests[id] else { continue }
      sentLog.append((connectionID: id, envelope: envelope))
      guest.deliverFromHost(frame, chunkSize: chunkSize)
    }
  }

  public func close(connectionID: UUID) {
    guard let guest = guests.removeValue(forKey: connectionID) else { return }
    decoders.removeValue(forKey: connectionID)
    closedConnectionIDs.append(connectionID)
    guest.hostClosedConnection()
    emit(.disconnected(connectionID, reason: .closedLocally))
  }

  /// Simulates a listener state change (e.g. `.failed(...)` after the app was suspended).
  public func simulateListenerState(_ state: HostListenerState) {
    emit(.listenerStateChanged(state))
  }

  // MARK: Guest-facing

  fileprivate func attach(_ guest: MockGuestTransport) {
    guests[guest.connectionID] = guest
    decoders[guest.connectionID] = FrameDecoder()
    emit(.connected(guest.connectionID))
  }

  fileprivate func receiveFrame(_ frame: Data, from connectionID: UUID) {
    guard guests[connectionID] != nil, var decoder = decoders[connectionID] else { return }
    decoder.append(frame)
    do {
      while let envelope = try decoder.nextEnvelope() {
        emit(.received(connectionID: connectionID, envelope: envelope))
      }
      decoders[connectionID] = decoder
    } catch {
      let guest = guests.removeValue(forKey: connectionID)
      decoders.removeValue(forKey: connectionID)
      guest?.hostClosedConnection()
      emit(.disconnected(connectionID, reason: .protocolError))
    }
  }

  fileprivate func guestDisconnected(_ connectionID: UUID, reason: TransportDisconnectReason) {
    guard guests.removeValue(forKey: connectionID) != nil else { return }
    decoders.removeValue(forKey: connectionID)
    emit(.disconnected(connectionID, reason: reason))
  }

  private func emit(_ event: HostTransportEvent) {
    switch delivery {
    case .immediate:
      onEvent?(event)
    case .mainQueue:
      DispatchQueue.main.async { [self] in
        onEvent?(event)
      }
    }
  }
}

/// In-memory guest transport paired with a `MockHostTransport`. Main thread only.
///
/// Every `connect()` after the first one attaches as a *new* connection (new `connectionID`), like a real reconnect.
public final class MockGuestTransport: GuestSessionTransport, @unchecked Sendable {
  public var onEvent: (@Sendable (GuestTransportEvent) -> Void)?
  public var delivery: MockDelivery = .immediate
  /// When set, frames sent to the host are split into chunks of at most this many bytes.
  public var chunkSize: Int?
  /// When false, `connect()` attaches to the host but does not emit `.connected` until `finishConnect()`.
  public var emitsConnectedOnConnect = true
  /// Half-open connection: when true, frames in both directions are silently dropped.
  public var isSilenced = false
  /// When set, the next `connect()` fails with this reason instead of attaching.
  public var nextConnectFailure: TransportDisconnectReason?

  public private(set) var connectionID: UUID
  public private(set) var connectCount = 0
  public private(set) var isConnected = false
  /// Raw frames received from the host (before decoding), in order.
  public private(set) var receivedFrames: [Data] = []
  public private(set) var receivedEnvelopes: [WireEnvelope] = []

  private weak var host: MockHostTransport?
  private var isAttached = false
  private var decoder = FrameDecoder()

  public init(host: MockHostTransport, connectionID: UUID = UUID()) {
    self.host = host
    self.connectionID = connectionID
  }

  public func connect() throws {
    if isAttached {
      detach(localReason: .closedLocally, hostReason: .closedByPeer)
    }
    connectCount += 1
    if connectCount > 1 {
      connectionID = UUID()
    }
    if let failure = nextConnectFailure {
      nextConnectFailure = nil
      emit(.disconnected(failure))
      return
    }
    guard let host, host.isRunning else {
      emit(.disconnected(.timedOut))
      return
    }
    decoder = FrameDecoder()
    isAttached = true
    host.attach(self)
    if emitsConnectedOnConnect {
      finishConnect()
    }
  }

  public func finishConnect() {
    guard isAttached, !isConnected else { return }
    isConnected = true
    emit(.connected)
  }

  public func disconnect() {
    guard isAttached else { return }
    detach(localReason: .closedLocally, hostReason: .closedByPeer)
  }

  public func send(_ envelope: WireEnvelope) throws {
    let frame = try FrameCodec.encode(envelope)
    sendRawFrame(frame)
  }

  /// Sends raw bytes (e.g. a hand-built legacy v1 frame).
  public func sendRawFrame(_ frame: Data) {
    guard isConnected, !isSilenced, let host else { return }
    let connectionID = self.connectionID
    for chunk in Self.chunks(of: frame, size: chunkSize) {
      schedule { [weak host] in
        host?.receiveFrame(chunk, from: connectionID)
      }
    }
  }

  /// The network dropped: both sides see a failure (the host keeps the guest's seat).
  public func simulateConnectionLoss() {
    guard isAttached else { return }
    detach(localReason: .failed("simulated connection loss"), hostReason: .failed("simulated connection loss"))
  }

  // MARK: Host-facing

  fileprivate func deliverFromHost(_ frame: Data, chunkSize: Int?) {
    guard isConnected, !isSilenced else { return }
    receivedFrames.append(frame)
    let expectedConnectionID = connectionID
    for chunk in Self.chunks(of: frame, size: chunkSize) {
      // Gate on the connection id only: frames sent before a close are still delivered (send-then-close).
      schedule { [weak self] in
        guard let self, self.connectionID == expectedConnectionID else { return }
        self.consume(chunk)
      }
    }
  }

  fileprivate func hostClosedConnection() {
    guard isAttached else { return }
    isAttached = false
    isConnected = false
    emit(.disconnected(.closedByPeer))
  }

  // MARK: Private

  private func consume(_ chunk: Data) {
    decoder.append(chunk)
    do {
      while let envelope = try decoder.nextEnvelope() {
        receivedEnvelopes.append(envelope)
        onEvent?(.received(envelope))
      }
    } catch {
      detach(localReason: .protocolError, hostReason: .closedByPeer)
    }
  }

  private func detach(localReason: TransportDisconnectReason, hostReason: TransportDisconnectReason) {
    isAttached = false
    isConnected = false
    let connectionID = self.connectionID
    // Same scheduling as frames, so the host still receives everything sent before the close.
    schedule { [weak host = self.host] in
      host?.guestDisconnected(connectionID, reason: hostReason)
    }
    emit(.disconnected(localReason))
  }

  private func emit(_ event: GuestTransportEvent) {
    schedule { [weak self] in
      self?.onEvent?(event)
    }
  }

  private func schedule(_ work: @escaping @Sendable () -> Void) {
    switch delivery {
    case .immediate:
      work()
    case .mainQueue:
      DispatchQueue.main.async {
        work()
      }
    }
  }

  private static func chunks(of frame: Data, size: Int?) -> [Data] {
    guard let size, size > 0, frame.count > size else { return [frame] }
    var chunks: [Data] = []
    var offset = frame.startIndex
    while offset < frame.endIndex {
      let end = min(offset + size, frame.endIndex)
      chunks.append(frame.subdata(in: offset..<end))
      offset = end
    }
    return chunks
  }
}
