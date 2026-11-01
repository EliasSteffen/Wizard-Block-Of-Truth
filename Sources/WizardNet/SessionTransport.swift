import Foundation

/// Why a network operation is stuck or failed, in terms the app can explain to the user.
public enum TransportFailure: Sendable, Equatable {
  /// The user denied (or has not yet granted) Local Network access (Settings › Privacy & Security › Local Network).
  case localNetworkDenied
  /// Any other network error; the text is for logs only.
  case network(String)
}

/// How a connection ended. Each connection reports exactly one `disconnected` event.
public enum TransportDisconnectReason: Sendable, Equatable {
  /// This side closed it (`close(connectionID:)`, `disconnect()`, `stop()`, or a new `connect()`).
  case closedLocally
  /// The peer closed the stream cleanly.
  case closedByPeer
  /// Guest only: the connection did not become ready within the connect timeout.
  case timedOut
  /// Guest only: the connection could not be established because Local Network access is denied.
  case localNetworkDenied
  /// The network failed (Wi-Fi lost, peer vanished, …); the text is for logs only.
  case failed(String)
  /// The peer sent bytes that are not a valid frame/envelope.
  case protocolError
}

/// State of the host's Bonjour listener (surfaced so the host UI can show session health and restart it).
public enum HostListenerState: Sendable, Equatable {
  case starting
  case ready
  case waiting(TransportFailure)
  case failed(TransportFailure)
  case stopped
}

public enum HostTransportEvent: Sendable, Equatable {
  case listenerStateChanged(HostListenerState)
  case connected(UUID)
  case disconnected(UUID, reason: TransportDisconnectReason)
  case received(connectionID: UUID, envelope: WireEnvelope)
}

public enum GuestTransportEvent: Sendable, Equatable {
  /// The connection attempt is stalled (e.g. Local Network permission denied); it keeps retrying until the timeout.
  case waiting(TransportFailure)
  case connected
  /// Ends every `connect()` attempt exactly once (also attempts that never became `connected`).
  case disconnected(TransportDisconnectReason)
  case received(WireEnvelope)
}

/// Host side of the wire. Implementations deliver `onEvent` callbacks serially (from one queue, in order).
public protocol HostSessionTransport: AnyObject, Sendable {
  var onEvent: (@Sendable (HostTransportEvent) -> Void)? { get set }
  /// Starts listening/advertising.
  func start() throws
  /// Re-creates the listener with the same Bonjour service name (e.g. after it failed while the app was
  /// suspended). Existing connections are kept.
  func restartListener()
  /// Gracefully closes every connection (after flushing already queued sends) and stops listening.
  func stop()
  /// Sends one envelope to each of the given connections (encoded once). Unknown ids are ignored.
  func send(_ envelope: WireEnvelope, to connectionIDs: [UUID]) throws
  /// Gracefully closes one connection after everything queued for it was sent ("send-then-close").
  func close(connectionID: UUID)
}

extension HostSessionTransport {
  public func send(_ envelope: WireEnvelope, to connectionID: UUID) throws {
    try send(envelope, to: [connectionID])
  }
}

/// Guest side of the wire. Implementations deliver `onEvent` callbacks serially (from one queue, in order).
public protocol GuestSessionTransport: AnyObject, Sendable {
  var onEvent: (@Sendable (GuestTransportEvent) -> Void)? { get set }
  /// Opens a new connection. A previous connection (if any) is closed first and reports `.closedLocally`.
  /// Can be called again after a disconnect to reconnect.
  func connect() throws
  /// Gracefully closes the current connection (queued sends are flushed first).
  func disconnect()
  func send(_ envelope: WireEnvelope) throws
}
