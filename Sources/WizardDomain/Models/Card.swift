import Foundation

public struct Card: Hashable, Codable, Sendable {
  public var image: String?
  public var name: String
  public var description: String

  public init(image: String? = nil, name: String, description: String) {
    self.image = image
    self.name = name
    self.description = description
  }
}
