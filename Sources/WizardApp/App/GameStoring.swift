import Foundation
import Combine
#if canImport(WizardDomain)
import WizardDomain
#endif

@MainActor
protocol GameStoring: AnyObject {
  var currentGame: Game? { get }
  var lastError: Error? { get set }
  var didAttemptLoad: Bool { get }
  var objectWillChange: ObservableObjectPublisher { get }

  func loadGame(id: UUID)
  func apply(_ command: GameCommand)
  @discardableResult
  func applyBatch(_ commands: [GameCommand], validate: ((Game) throws -> Void)?) -> Error?
}

extension GameStoring {
  @discardableResult
  func applyBatch(_ commands: [GameCommand]) -> Error? {
    applyBatch(commands, validate: nil)
  }
}
