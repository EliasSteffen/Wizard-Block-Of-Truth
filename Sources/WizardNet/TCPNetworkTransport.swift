import Foundation
import Network
import os

private let netLog = Logger(subsystem: "WizardBlockOfTruth", category: "WizardNet")

/// Bonjour constants of the multi-phone service (must match `NSBonjourServices` in Info.plist).
public enum WizardBonjour {
  public static let serviceType = "_wizardbot._tcp"
  public static let domain = "local."
  /// DNS-SD instance names are limited to 63 UTF-8 bytes.
  public static let maxServiceNameBytes = 63
}

enum WizardTCP {
  static let connectTimeout: TimeInterval = 10
  static let closeGracePeriod: TimeInterval = 2
  /// `kDNSServiceErr_PolicyDenied`: Local Network access was denied.
  static let dnsPolicyDenied: Int32 = -65570

  static func parameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    // Small request/response messages: don't let Nagle hold back a `commandResult` + snapshot pair.
    tcp.noDelay = true
    // Detect dead peers at the TCP level as well (the app-level heartbeat is the primary mechanism).
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 3
    tcp.connectionTimeout = Int(connectTimeout)
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.includePeerToPeer = true
    return parameters
  }

  static func failure(from error: NWError, path: NWPath?) -> TransportFailure {
    if let path, path.unsatisfiedReason == .localNetworkDenied {
      return .localNetworkDenied
    }
    if case .dns(let code) = error, code == dnsPolicyDenied {
      return .localNetworkDenied
    }
    return .network(String(describing: error))
  }
}

/// Thread-safe holder for a transport's event callback (set on the main actor, read on the transport queue).
final class EventHandlerBox<Event: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: (@Sendable (Event) -> Void)?

  var handler: (@Sendable (Event) -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }

  func emit(_ event: Event) {
    handler?(event)
  }
}

public struct DiscoveredSession: Identifiable, Equatable, Hashable, Sendable {
  public var id: String
  public var code: String
  public var displayName: String
  /// Full Bonjour instance name; guests connect (and reconnect) by this name.
  public var serviceName: String

  public init(id: String, code: String, displayName: String, serviceName: String? = nil) {
    self.id = id
    self.code = code
    self.displayName = displayName
    self.serviceName = serviceName ?? id
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

  public init(serviceType: String = WizardBonjour.serviceType, sessionCode: String, gameName: String) {
    self.serviceType = serviceType
    self.sessionCode = sessionCode
    self.serviceName = Self.serviceName(sessionCode: sessionCode, gameName: gameName)
  }

  public func listenerService() -> NWListener.Service {
    NWListener.Service(name: serviceName, type: serviceType)
  }

  /// `"{code}-{game name}"`, truncated on a character boundary to at most 63 UTF-8 bytes.
  /// Deterministic for the same code and game name, so a restarted/relaunched host re-advertises the same name.
  public static func serviceName(sessionCode: String, gameName: String) -> String {
    let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = trimmed.isEmpty ? "Wizard" : trimmed
    return truncated("\(sessionCode)-\(displayName)", maxUTF8Bytes: WizardBonjour.maxServiceNameBytes)
  }

  public static func truncated(_ value: String, maxUTF8Bytes: Int) -> String {
    guard value.utf8.count > maxUTF8Bytes else { return value }
    var result = ""
    var byteCount = 0
    for character in value {
      let size = String(character).utf8.count
      if byteCount + size > maxUTF8Bytes { break }
      result.append(character)
      byteCount += size
    }
    return result
  }
}

public enum BonjourBrowserState: Sendable, Equatable {
  case idle
  case browsing
  case waiting(TransportFailure)
  case failed(TransportFailure)
}

/// Discovers hosted sessions. Callbacks run on the main queue.
@MainActor
public final class BonjourBrowser: ObservableObject {
  @Published public private(set) var sessions: [DiscoveredSession] = []
  /// `.waiting(.localNetworkDenied)` / `.failed(...)` explain an empty list.
  @Published public private(set) var state: BonjourBrowserState = .idle

  private let serviceType: String
  private var browser: NWBrowser?
  private var generation = 0

  public init(serviceType: String = WizardBonjour.serviceType) {
    self.serviceType = serviceType
  }

  public func start() {
    stop()
    generation += 1
    let currentGeneration = generation
    let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
    let browser = NWBrowser(for: descriptor, using: WizardTCP.parameters())
    self.browser = browser
    state = .browsing

    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let sessions = BonjourBrowser.sessions(from: results)
      MainActor.assumeIsolated {
        self?.apply(sessions: sessions, generation: currentGeneration)
      }
    }
    browser.stateUpdateHandler = { [weak self] newState in
      let mapped = BonjourBrowser.browserState(from: newState)
      MainActor.assumeIsolated {
        self?.apply(state: mapped, generation: currentGeneration)
      }
    }
    browser.start(queue: .main)
  }

  public func stop() {
    generation += 1
    browser?.cancel()
    browser = nil
    sessions = []
    state = .idle
  }

  /// Restarts browsing (e.g. after the app returned to the foreground or the user granted Local Network access).
  public func restart() {
    start()
  }

  private func apply(sessions: [DiscoveredSession], generation: Int) {
    guard generation == self.generation else { return }
    self.sessions = sessions
  }

  private func apply(state: BonjourBrowserState?, generation: Int) {
    guard generation == self.generation, let state else { return }
    self.state = state
  }

  private nonisolated static func sessions(from results: Set<NWBrowser.Result>) -> [DiscoveredSession] {
    var sessions: [DiscoveredSession] = []
    for result in results {
      switch result.endpoint {
      case .service(let name, _, _, _):
        let parsed = BonjourServiceDescriptor.parse(serviceName: name)
        sessions.append(
          DiscoveredSession(id: name, code: parsed.code, displayName: parsed.displayName, serviceName: name)
        )
      default:
        continue
      }
    }
    return sessions.sorted { lhs, rhs in
      if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
      return lhs.id < rhs.id
    }
  }

  private nonisolated static func browserState(from state: NWBrowser.State) -> BonjourBrowserState? {
    switch state {
    case .ready:
      return .browsing
    case .waiting(let error):
      return .waiting(WizardTCP.failure(from: error, path: nil))
    case .failed(let error):
      return .failed(WizardTCP.failure(from: error, path: nil))
    default:
      return nil
    }
  }
}

/// Host transport: `NWListener` advertising the session via Bonjour plus one `NWConnection` per guest.
///
/// Thread-safety: every mutable property is only touched on `queue` (public methods hop onto it), so the
/// `@unchecked Sendable` conformance is backed by queue confinement.
public final class TCPHostTransport: HostSessionTransport, @unchecked Sendable {
  private final class Connection {
    let connection: NWConnection
    var decoder = FrameDecoder()
    var didReportConnected = false
    var isClosing = false

    init(connection: NWConnection) {
      self.connection = connection
    }
  }

  private let queue = DispatchQueue(label: "wizardnet.host", qos: .userInitiated)
  private let handlers = EventHandlerBox<HostTransportEvent>()
  private let serviceName: String
  private let serviceType: String

  // Confined to `queue`.
  private var listener: NWListener?
  private var listenerGeneration = 0
  private var connections: [UUID: Connection] = [:]
  private var isStopped = true

  public var onEvent: (@Sendable (HostTransportEvent) -> Void)? {
    get { handlers.handler }
    set { handlers.handler = newValue }
  }

  public init(serviceName: String, serviceType: String = WizardBonjour.serviceType) {
    self.serviceName = serviceName
    self.serviceType = serviceType
  }

  public convenience init(advertiser: BonjourAdvertiser) throws {
    self.init(serviceName: advertiser.serviceName, serviceType: advertiser.serviceType)
  }

  public func start() throws {
    try queue.sync {
      isStopped = false
      try makeListener()
    }
  }

  public func restartListener() {
    queue.async { [self] in
      guard !isStopped else { return }
      do {
        try makeListener()
      } catch {
        netLog.error("Host listener restart failed: \(String(describing: error), privacy: .public)")
        handlers.emit(.listenerStateChanged(.failed(.network(String(describing: error)))))
      }
    }
  }

  public func stop() {
    queue.async { [self] in
      guard !isStopped else { return }
      isStopped = true
      listenerGeneration += 1
      listener?.cancel()
      listener = nil
      for id in Array(connections.keys) {
        closeGracefully(id)
      }
      handlers.emit(.listenerStateChanged(.stopped))
    }
  }

  public func send(_ envelope: WireEnvelope, to connectionIDs: [UUID]) throws {
    guard !connectionIDs.isEmpty else { return }
    let frame = try FrameCodec.encode(envelope)
    queue.async { [self] in
      for id in connectionIDs {
        guard let entry = connections[id], !entry.isClosing else { continue }
        entry.connection.send(content: frame, completion: .contentProcessed { error in
          if let error {
            netLog.error("Host send failed: \(String(describing: error), privacy: .public)")
          }
        })
      }
    }
  }

  public func close(connectionID: UUID) {
    queue.async { [self] in
      closeGracefully(connectionID)
    }
  }

  // MARK: - Queue-confined implementation

  private func makeListener() throws {
    listenerGeneration += 1
    let generation = listenerGeneration
    listener?.cancel()
    listener = nil

    let listener = try NWListener(using: WizardTCP.parameters(), on: .any)
    listener.service = NWListener.Service(name: serviceName, type: serviceType)
    listener.stateUpdateHandler = { [weak self] state in
      self?.listenerStateChanged(state, generation: generation)
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection, generation: generation)
    }
    listener.serviceRegistrationUpdateHandler = { change in
      if case .add(let endpoint) = change {
        netLog.info("Bonjour service registered: \(String(describing: endpoint), privacy: .public)")
      }
    }
    self.listener = listener
    handlers.emit(.listenerStateChanged(.starting))
    listener.start(queue: queue)
  }

  private func listenerStateChanged(_ state: NWListener.State, generation: Int) {
    guard generation == listenerGeneration, !isStopped else { return }
    switch state {
    case .ready:
      netLog.info("Host listener ready")
      handlers.emit(.listenerStateChanged(.ready))
    case .waiting(let error):
      netLog.error("Host listener waiting: \(String(describing: error), privacy: .public)")
      handlers.emit(.listenerStateChanged(.waiting(WizardTCP.failure(from: error, path: nil))))
    case .failed(let error):
      netLog.error("Host listener failed: \(String(describing: error), privacy: .public)")
      listener?.cancel()
      listener = nil
      handlers.emit(.listenerStateChanged(.failed(WizardTCP.failure(from: error, path: nil))))
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection, generation: Int) {
    guard !isStopped else {
      connection.cancel()
      return
    }
    let id = UUID()
    connections[id] = Connection(connection: connection)
    netLog.info("Host accepting inbound connection \(id.uuidString, privacy: .public)")
    connection.stateUpdateHandler = { [weak self] state in
      self?.connectionStateChanged(state, id: id)
    }
    connection.start(queue: queue)
  }

  private func connectionStateChanged(_ state: NWConnection.State, id: UUID) {
    guard let entry = connections[id] else { return }
    switch state {
    case .ready:
      guard !entry.didReportConnected else { return }
      entry.didReportConnected = true
      handlers.emit(.connected(id))
      receive(id)
    case .waiting(let error), .failed(let error):
      finish(id, reason: .failed(String(describing: error)))
    case .cancelled:
      finish(id, reason: .closedLocally)
    default:
      break
    }
  }

  private func receive(_ id: UUID) {
    guard let entry = connections[id] else { return }
    entry.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty, !self.consume(data, id: id) {
        return
      }
      if let error {
        self.finish(id, reason: .failed(String(describing: error)))
        return
      }
      if isComplete {
        self.finish(id, reason: .closedByPeer)
        return
      }
      self.receive(id)
    }
  }

  /// Returns false when the connection is gone (closed because of a framing/decoding error).
  private func consume(_ data: Data, id: UUID) -> Bool {
    guard let entry = connections[id] else { return false }
    entry.decoder.append(data)
    do {
      while let envelope = try entry.decoder.nextEnvelope() {
        guard !entry.isClosing else { continue }
        handlers.emit(.received(connectionID: id, envelope: envelope))
      }
      return true
    } catch {
      netLog.error("Host dropped connection \(id.uuidString, privacy: .public): invalid frame")
      finish(id, reason: .protocolError)
      return false
    }
  }

  /// Sends FIN after everything already queued, then cancels (or cancels after a grace period).
  private func closeGracefully(_ id: UUID) {
    guard let entry = connections[id], !entry.isClosing else { return }
    entry.isClosing = true
    guard entry.didReportConnected else {
      finish(id, reason: .closedLocally)
      return
    }
    entry.connection.send(
      content: nil,
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        self?.finish(id, reason: .closedLocally)
      }
    )
    queue.asyncAfter(deadline: .now() + WizardTCP.closeGracePeriod) { [weak self] in
      self?.finish(id, reason: .closedLocally)
    }
  }

  /// Removes the connection and reports exactly one `disconnected` event for it.
  private func finish(_ id: UUID, reason: TransportDisconnectReason) {
    guard let entry = connections.removeValue(forKey: id) else { return }
    entry.connection.cancel()
    if entry.didReportConnected {
      netLog.info("Host connection \(id.uuidString, privacy: .public) ended")
      handlers.emit(.disconnected(id, reason: reason))
    }
  }
}

/// Guest transport. Each `connect()` opens a fresh `NWConnection` (to a Bonjour service *name*, so reconnects
/// resolve the host again even if its port changed after a listener restart or an app relaunch).
///
/// Thread-safety: every mutable property is only touched on `queue` (public methods hop onto it).
public final class TCPGuestTransport: GuestSessionTransport, @unchecked Sendable {
  private enum Phase {
    case idle
    case connecting
    case ready
    case closing
  }

  /// The Bonjour instance name this transport connects to (nil for non-service endpoints).
  public let serviceName: String?

  private let queue = DispatchQueue(label: "wizardnet.guest", qos: .userInitiated)
  private let handlers = EventHandlerBox<GuestTransportEvent>()
  private let endpoint: NWEndpoint
  private let connectTimeout: TimeInterval

  // Confined to `queue`.
  private var connection: NWConnection?
  private var generation = 0
  private var phase: Phase = .idle
  private var decoder = FrameDecoder()
  private var lastWaitingFailure: TransportFailure?

  public var onEvent: (@Sendable (GuestTransportEvent) -> Void)? {
    get { handlers.handler }
    set { handlers.handler = newValue }
  }

  public init(endpoint: NWEndpoint, connectTimeout: TimeInterval = 10) {
    self.endpoint = endpoint
    self.connectTimeout = connectTimeout
    if case .service(let name, _, _, _) = endpoint {
      self.serviceName = name
    } else {
      self.serviceName = nil
    }
  }

  public convenience init(
    serviceName: String,
    serviceType: String = WizardBonjour.serviceType,
    domain: String = WizardBonjour.domain,
    connectTimeout: TimeInterval = 10
  ) {
    self.init(
      endpoint: .service(name: serviceName, type: serviceType, domain: domain, interface: nil),
      connectTimeout: connectTimeout
    )
  }

  public func connect() throws {
    queue.async { [self] in
      openConnection()
    }
  }

  public func disconnect() {
    queue.async { [self] in
      guard let connection else { return }
      guard phase == .ready else {
        finish(.closedLocally)
        return
      }
      phase = .closing
      let currentGeneration = generation
      connection.send(
        content: nil,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { [weak self] _ in
          guard let self, currentGeneration == self.generation else { return }
          self.finish(.closedLocally)
        }
      )
      queue.asyncAfter(deadline: .now() + WizardTCP.closeGracePeriod) { [weak self] in
        guard let self, currentGeneration == self.generation else { return }
        self.finish(.closedLocally)
      }
    }
  }

  public func send(_ envelope: WireEnvelope) throws {
    let frame = try FrameCodec.encode(envelope)
    queue.async { [self] in
      guard phase == .ready || phase == .closing, let connection else {
        netLog.debug("Guest send dropped: not connected")
        return
      }
      connection.send(content: frame, completion: .contentProcessed { error in
        if let error {
          netLog.error("Guest send failed: \(String(describing: error), privacy: .public)")
        }
      })
    }
  }

  // MARK: - Queue-confined implementation

  private func openConnection() {
    if connection != nil {
      finish(.closedLocally)
    }
    generation += 1
    let currentGeneration = generation
    let connection = NWConnection(to: endpoint, using: WizardTCP.parameters())
    self.connection = connection
    phase = .connecting
    decoder = FrameDecoder()
    lastWaitingFailure = nil
    netLog.info("Guest starting TCP connection")
    connection.stateUpdateHandler = { [weak self] state in
      self?.stateChanged(state, generation: currentGeneration)
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
      self?.connectTimedOut(generation: currentGeneration)
    }
  }

  private func stateChanged(_ state: NWConnection.State, generation stateGeneration: Int) {
    guard stateGeneration == generation, let connection else { return }
    switch state {
    case .ready:
      guard phase == .connecting else { return }
      phase = .ready
      lastWaitingFailure = nil
      netLog.info("Guest connection ready")
      handlers.emit(.connected)
      receive(generation: stateGeneration)
    case .waiting(let error):
      let failure = WizardTCP.failure(from: error, path: connection.currentPath)
      netLog.error("Guest connection waiting: \(String(describing: error), privacy: .public)")
      guard failure != lastWaitingFailure else { return }
      lastWaitingFailure = failure
      handlers.emit(.waiting(failure))
    case .failed(let error):
      netLog.error("Guest connection failed: \(String(describing: error), privacy: .public)")
      let failure = WizardTCP.failure(from: error, path: connection.currentPath)
      finish(failure == .localNetworkDenied ? .localNetworkDenied : .failed(String(describing: error)))
    case .cancelled:
      finish(.closedLocally)
    default:
      break
    }
  }

  private func connectTimedOut(generation timerGeneration: Int) {
    guard timerGeneration == generation, phase == .connecting else { return }
    netLog.error("Guest connection timed out")
    finish(lastWaitingFailure == .localNetworkDenied ? .localNetworkDenied : .timedOut)
  }

  private func receive(generation receiveGeneration: Int) {
    guard receiveGeneration == generation, let connection else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self, receiveGeneration == self.generation else { return }
      if let data, !data.isEmpty {
        self.decoder.append(data)
        do {
          while let envelope = try self.decoder.nextEnvelope() {
            self.handlers.emit(.received(envelope))
          }
        } catch {
          netLog.error("Guest dropped connection: invalid frame")
          self.finish(.protocolError)
          return
        }
      }
      if let error {
        self.finish(.failed(String(describing: error)))
        return
      }
      if isComplete {
        self.finish(self.phase == .closing ? .closedLocally : .closedByPeer)
        return
      }
      self.receive(generation: receiveGeneration)
    }
  }

  /// Ends the current connection and reports exactly one `disconnected` event for it.
  private func finish(_ reason: TransportDisconnectReason) {
    guard let connection else { return }
    self.connection = nil
    generation += 1
    phase = .idle
    connection.cancel()
    handlers.emit(.disconnected(reason))
  }
}
