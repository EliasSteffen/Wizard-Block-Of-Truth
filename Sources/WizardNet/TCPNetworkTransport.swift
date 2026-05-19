import Foundation
import Network
import os

private let netLog = Logger(subsystem: "WizardBlockOfTruth", category: "WizardNet")

enum WizardTCP {
  static func parameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    return parameters
  }
}

public struct DiscoveredSession: Identifiable, Equatable {
  public var id: String
  public var code: String
  public var displayName: String

  public init(id: String, code: String, displayName: String) {
    self.id = id
    self.code = code
    self.displayName = displayName
  }
}

public enum BonjourServiceDescriptor {
  /// Parses `"{sessionCode}-{displayName}"` from the Bonjour service name.
  public static func parse(serviceName: String) -> (code: String, displayName: String) {
    let parts = serviceName.split(separator: "-", maxSplits: 1).map(String.init)
    if parts.count == 2 {
      return (code: parts[0], displayName: parts[1])
    }
    return (code: "------", displayName: serviceName)
  }
}

public enum SessionCode {
  private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

  public static func random(length: Int = 6) -> String {
    var code = ""
    code.reserveCapacity(length)
    for _ in 0..<length {
      code.append(alphabet[Int.random(in: 0..<alphabet.count)])
    }
    return code
  }
}

public final class BonjourAdvertiser {
  public let serviceType: String
  public private(set) var sessionCode: String
  public private(set) var serviceName: String

  public init(serviceType: String = "_wizardbot._tcp", sessionCode: String, gameName: String) {
    self.serviceType = serviceType
    self.sessionCode = sessionCode
    self.serviceName = "\(sessionCode)-\(Self.sanitize(gameName))"
  }

  public func listenerService() -> NWListener.Service {
    NWListener.Service(name: serviceName, type: serviceType)
  }

  private static func sanitize(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Wizard" }
    return String(trimmed.prefix(32))
  }
}

@MainActor
public final class BonjourBrowser: ObservableObject {
  @Published public private(set) var sessions: [DiscoveredSession] = []

  private let serviceType: String
  private var browser: NWBrowser?
  private var endpointByID: [String: NWEndpoint] = [:]
  private let queue = DispatchQueue(label: "wizardnet.browser")

  public init(serviceType: String = "_wizardbot._tcp") {
    self.serviceType = serviceType
  }

  public func start() {
    stop()
    let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
    let browser = NWBrowser(for: descriptor, using: WizardTCP.parameters())
    self.browser = browser

    browser.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self else { return }
      Task { @MainActor [weak self] in
        self?.consume(results: results)
      }
    }
    browser.stateUpdateHandler = { _ in }
    browser.start(queue: queue)
  }

  public func stop() {
    browser?.cancel()
    browser = nil
    endpointByID.removeAll()
    sessions = []
  }

  public func makeGuestTransport(sessionID: String) -> TCPGuestTransport? {
    guard let endpoint = endpointByID[sessionID] else { return nil }
    return TCPGuestTransport(endpoint: endpoint)
  }

  private func consume(results: Set<NWBrowser.Result>) {
    var newSessions: [DiscoveredSession] = []
    var newEndpointByID: [String: NWEndpoint] = [:]
    for result in results {
      let endpoint = result.endpoint
      let descriptor = endpointDescriptor(for: endpoint)
      let code = descriptor.code
      let name = descriptor.name
      newEndpointByID[descriptor.id] = endpoint
      newSessions.append(DiscoveredSession(id: descriptor.id, code: code, displayName: name))
    }
    sessions = newSessions.sorted(by: { $0.displayName < $1.displayName })
    endpointByID = newEndpointByID
  }

  private func endpointDescriptor(for endpoint: NWEndpoint) -> (id: String, code: String, name: String) {
    switch endpoint {
    case .service(let name, _, _, _):
      let parsed = BonjourServiceDescriptor.parse(serviceName: name)
      return (id: name, code: parsed.code, name: parsed.displayName)
    default:
      let description = "\(endpoint)"
      return (id: description, code: "------", name: description)
    }
  }
}

public final class TCPHostTransport: HostSessionTransport {
  public var onEvent: (@Sendable (HostTransportEvent) -> Void)?

  private struct ConnectionState {
    var connection: NWConnection
    var decoder: FrameDecoder
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "wizardnet.host", qos: .userInitiated)
  private var connections: [UUID: ConnectionState] = [:]

  public init(advertiser: BonjourAdvertiser) throws {
    let listener = try NWListener(using: WizardTCP.parameters(), on: .any)
    listener.service = advertiser.listenerService()
    self.listener = listener
  }

  public func start() throws {
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection: connection)
    }
    listener.stateUpdateHandler = { _ in }
    listener.start(queue: queue)
  }

  public func stop() {
    for state in connections.values {
      state.connection.cancel()
    }
    connections.removeAll()
    listener.cancel()
  }

  public func send(_ envelope: WireEnvelope, to connectionID: UUID) throws {
    guard let state = connections[connectionID] else { return }
    let frame = try FrameCodec.encode(envelope)
    state.connection.send(content: frame, completion: .contentProcessed { _ in })
  }

  public func broadcast(_ envelope: WireEnvelope) throws {
    let frame = try FrameCodec.encode(envelope)
    for state in connections.values {
      state.connection.send(content: frame, completion: .contentProcessed { _ in })
    }
  }

  private func accept(connection: NWConnection) {
    let connectionID = UUID()
    connections[connectionID] = ConnectionState(connection: connection, decoder: FrameDecoder())
    netLog.info("Host accepting inbound connection \(connectionID.uuidString, privacy: .public)")
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        netLog.info("Host connection ready \(connectionID.uuidString, privacy: .public)")
        self.onEvent?(.connected(connectionID))
        self.receiveLoop(connectionID: connectionID)
      case .failed(let error):
        netLog.error("Host connection failed \(connectionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        self.connections.removeValue(forKey: connectionID)
        self.onEvent?(.disconnected(connectionID))
      case .cancelled:
        netLog.debug("Host connection cancelled \(connectionID.uuidString, privacy: .public)")
        self.connections.removeValue(forKey: connectionID)
        self.onEvent?(.disconnected(connectionID))
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func receiveLoop(connectionID: UUID) {
    guard let state = connections[connectionID] else { return }
    state.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.consumeIncomingData(data, connectionID: connectionID)
      }
      if isComplete || error != nil {
        self.connections[connectionID]?.connection.cancel()
        self.connections.removeValue(forKey: connectionID)
        self.onEvent?(.disconnected(connectionID))
        return
      }
      self.receiveLoop(connectionID: connectionID)
    }
  }

  private func consumeIncomingData(_ data: Data, connectionID: UUID) {
    guard var state = connections[connectionID] else { return }
    state.decoder.append(data)
    connections[connectionID] = state

    while true {
      do {
        guard let envelope = try state.decoder.nextEnvelope() else { break }
        onEvent?(.received(connectionID: connectionID, envelope: envelope))
        if var latest = connections[connectionID] {
          latest.decoder = state.decoder
          connections[connectionID] = latest
        }
      } catch {
        connections[connectionID]?.connection.cancel()
        connections.removeValue(forKey: connectionID)
        onEvent?(.disconnected(connectionID))
        break
      }
    }
  }
}

extension TCPHostTransport: @unchecked Sendable {}

public final class TCPGuestTransport: GuestSessionTransport {
  public var onEvent: (@Sendable (GuestTransportEvent) -> Void)?

  private let connection: NWConnection
  private let queue = DispatchQueue(label: "wizardnet.guest", qos: .userInitiated)
  private var decoder = FrameDecoder()
  private var hasStarted = false
  private var isDisconnected = false

  public init(endpoint: NWEndpoint) {
    self.connection = NWConnection(to: endpoint, using: WizardTCP.parameters())
  }

  public func connect() throws {
    guard !hasStarted else {
      netLog.debug("Guest connect ignored; connection already started")
      return
    }
    hasStarted = true
    netLog.info("Guest starting TCP connection")
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        netLog.info("Guest connection ready")
        self.onEvent?(.connected)
        self.receiveLoop()
      case .failed(let error):
        netLog.error("Guest connection failed: \(error.localizedDescription, privacy: .public)")
        self.markDisconnected()
      case .cancelled:
        netLog.debug("Guest connection cancelled")
        self.markDisconnected()
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  public func disconnect() {
    guard !isDisconnected else { return }
    isDisconnected = true
    connection.cancel()
  }

  public func send(_ envelope: WireEnvelope) throws {
    let frame = try FrameCodec.encode(envelope)
    connection.send(content: frame, completion: .contentProcessed { error in
      if let error {
        netLog.error("Guest send failed: \(error.localizedDescription, privacy: .public)")
      }
    })
  }

  private func markDisconnected() {
    guard !isDisconnected else { return }
    isDisconnected = true
    onEvent?(.disconnected)
  }

  private func receiveLoop() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.decoder.append(data)
        while true {
          do {
            guard let envelope = try self.decoder.nextEnvelope() else { break }
            self.onEvent?(.received(envelope))
          } catch {
            self.markDisconnected()
            self.disconnect()
            return
          }
        }
      }
      if isComplete || error != nil {
        self.markDisconnected()
        self.disconnect()
        return
      }
      self.receiveLoop()
    }
  }
}

extension TCPGuestTransport: @unchecked Sendable {}
