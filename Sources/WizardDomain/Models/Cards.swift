import Foundation

public enum Cards {
  public static let Bomb = Card(
    image: nil,
    name: "Bomb",
    description: "Removes the trick from the Round."
  )
  public static let Cloud = Card(
    image: nil,
    name: "Cloud",
    description: "The Player who won the trick containing the Cloud-Card must increase or decrease his bet by 1."
  )
}
