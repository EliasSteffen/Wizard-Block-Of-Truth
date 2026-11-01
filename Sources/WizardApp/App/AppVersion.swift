import Foundation

/// Numeric dotted version (`CFBundleShortVersionString` style) with proper component-wise comparison:
/// `1.10 > 1.9`, and missing trailing components count as zero (`1.2 == 1.2.0`).
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
  let components: [Int]

  /// Returns `nil` unless `string` consists of one or more dot-separated non-negative integers.
  init?(_ string: String) {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var parsed: [Int] = []
    for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
      guard !part.isEmpty,
            part.allSatisfy({ $0.isASCII && $0.isNumber }),
            let number = Int(part)
      else { return nil }
      parsed.append(number)
    }
    components = parsed
  }

  var description: String {
    components.map { String($0) }.joined(separator: ".")
  }

  static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
    compare(lhs, rhs) == 0
  }

  static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    compare(lhs, rhs) < 0
  }

  /// Negative when `lhs < rhs`, zero when equal, positive when `lhs > rhs`.
  private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right {
        return left < right ? -1 : 1
      }
    }
    return 0
  }
}
