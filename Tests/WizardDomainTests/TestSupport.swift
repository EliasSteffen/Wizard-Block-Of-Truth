import Foundation
import WizardDomain

enum TestSupport {
  static func makePlayers(_ n: Int) -> [Player] {
    (0..<n).map { idx in
      Player(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!, name: "P\(idx + 1)")
    }
  }
}

