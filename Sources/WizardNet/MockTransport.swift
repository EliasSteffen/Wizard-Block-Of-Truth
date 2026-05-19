import Foundation

public final class MockHostTransport: HostSessionTransport {
  public var onEvent: (@Sendable (HostTransportEvent) -> Void)?

  private var guests: [UUID: MockGuestTransport] = [:]
  private var isRunning = false

  public init() {}

  public func start() throws {
    isRunning = true
  }

  public func stop() {
    isRunning = false
    let allGuestIDs = Array(guests.keys)
    for guestID in allGuestIDs {
      guests[guestID]?.detach()
      onEvent?(.disconnected(guestID))
    }
    guests.removeAll()
  }

  public func send(_ envelope: WireEnvelope, to connectionID: UUID) throws {
    guard isRunning, let guest = guests[connectionID] else { return }
    guest.receiveFromHost(envelope)
  }

  public func broadcast(_ envelope: WireEnvelope) throws {
    guard isRunning else { return }
    for guest in guests.values {
      guest.receiveFromHost(envelope)
    }
  }

  fileprivate func attach(_ guest: MockGuestTransport) {
    guests[guest.connectionID] = guest
    onEvent?(.connected(guest.connectionID))
  }

  fileprivate func receiveFromGuest(_ envelope: WireEnvelope, connectionID: UUID) {
    onEvent?(.received(connectionID: connectionID, envelope: envelope))
  }

  fileprivate func disconnect(_ connectionID: UUID) {
    guests.removeValue(forKey: connectionID)
    onEvent?(.disconnected(connectionID))
  }
}

public final class MockGuestTransport: GuestSessionTransport {
  public var onEvent: (@Sendable (GuestTransportEvent) -> Void)?

  public let connectionID: UUID
  /// When false, `connect()` attaches to the host but does not emit `.connected` until `finishConnect()`.
  public var emitsConnectedOnConnect = true
  private weak var host: MockHostTransport?
  private var isConnected = false
  private var isAttached = false

  public init(host: MockHostTransport, connectionID: UUID = UUID()) {
    self.host = host
    self.connectionID = connectionID
  }

  public func connect() throws {
    guard !isConnected, let host else { return }
    if !isAttached {
      isAttached = true
      host.attach(self)
    }
    if emitsConnectedOnConnect {
      finishConnect()
    }
  }

  public func finishConnect() {
    guard isAttached, !isConnected else { return }
    isConnected = true
    onEvent?(.connected)
  }

  public func disconnect() {
    if isAttached {
      host?.disconnect(connectionID)
      isAttached = false
    }
    guard isConnected else { return }
    isConnected = false
    onEvent?(.disconnected)
  }

  fileprivate func detach() {
    isAttached = false
    isConnected = false
    onEvent?(.disconnected)
  }

  public func send(_ envelope: WireEnvelope) throws {
    guard isConnected else { return }
    host?.receiveFromGuest(envelope, connectionID: connectionID)
  }

  fileprivate func receiveFromHost(_ envelope: WireEnvelope) {
    guard isConnected else { return }
    onEvent?(.received(envelope))
  }
}
