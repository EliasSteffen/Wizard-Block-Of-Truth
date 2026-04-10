import Foundation

public enum Cards {
  public static let Bomb = Card(
    image: nil,
    name: String(localized: "Domain.Card.Bomb.Name", defaultValue: "Bomb"),
    description: String(localized: "Domain.Card.Bomb.Description", defaultValue: "Removes the trick from the Round.")
  )
  public static let Cloud = Card(
    image: nil,
    name: String(localized: "Domain.Card.Cloud.Name", defaultValue: "Cloud"),
    description: String(localized: "Domain.Card.Cloud.Description", defaultValue: "The Player who won the trick containing the Cloud-Card must increase or decrease his bet by 1.")
  )
}
