import Foundation
import SwiftData

@Model
final class GameSnapshotEntity {
  @Attribute(.unique) var id: UUID
  var name: String
  var createdAt: Date
  var updatedAt: Date
  var gameJSON: Data

  init(id: UUID, name: String, createdAt: Date = .now, updatedAt: Date = .now, gameJSON: Data) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.gameJSON = gameJSON
  }
}

