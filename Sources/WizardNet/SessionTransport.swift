import Foundation

public enum HostTransportEvent: Sendable, Equatable {
  case connected(UUID)
  case disconnected(UUID)
  case received(connectionID: UUID, envelope: WireEnvelope)
}

public enum GuestTransportEvent: Sendable, Equatable {
  case connected
  case disconnected
  case received(WireEnvelope)
}

public protocol HostSessionTransport: AnyObject {
  var onEvent: (@Sendable (HostTransportEvent) -> Void)? { get set }
  func start() throws
  func stop()
  func send(_ envelope: WireEnvelope, to connectionID: UUID) throws
  func broadcast(_ envelope: WireEnvelope) throws
}

public protocol GuestSessionTransport: AnyObject {
  var onEvent: (@Sendable (GuestTransportEvent) -> Void)? { get set }
  func connect() throws
  func disconnect()
  func send(_ envelope: WireEnvelope) throws
}
