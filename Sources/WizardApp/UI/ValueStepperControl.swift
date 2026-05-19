import SwiftUI

enum ValueStepperStyle {
  case compact
  case prominent
}

struct ValueStepperControl: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  var isDisabled: Bool = false
  var style: ValueStepperStyle = .compact

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    switch style {
    case .compact:
      compactBody
    case .prominent:
      prominentBody
    }
  }

  private var compactBody: some View {
    HStack(spacing: 10) {
      stepButton(symbol: String(localized: "UI.Common.Symbol.Minus", defaultValue: "-"), delta: -1, compact: true)
      TextField("", text: $text)
        .focused($isFocused)
        .disabled(isDisabled)
        .multilineTextAlignment(.center)
        .frame(width: 44)
        .font(.headline)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.65), in: Capsule())
#if os(iOS)
        .keyboardType(.numberPad)
        .textInputAutocapitalization(.never)
#endif
      stepButton(symbol: String(localized: "UI.Common.Symbol.Plus", defaultValue: "+"), delta: 1, compact: true)
    }
    .onAppear {
      text = "\(value)"
    }
    .onChange(of: range) { _, newRange in
      let clamped = min(newRange.upperBound, max(newRange.lowerBound, value))
      if clamped != value {
        value = clamped
      }
    }
    .onChange(of: isDisabled) { _, disabled in
      if disabled {
        isFocused = false
      }
    }
    .onChange(of: value) { _, newValue in
      guard !isFocused else { return }
      text = "\(newValue)"
    }
    .onChange(of: text) { _, newValue in
      let filtered = newValue.filter(\.isNumber)
      if filtered != newValue {
        text = filtered
        return
      }
      guard let parsed = Int(filtered) else { return }
      let clamped = min(range.upperBound, max(range.lowerBound, parsed))
      if clamped != value {
        value = clamped
      }
    }
  }

  private var prominentBody: some View {
    HStack(spacing: 24) {
      stepButton(symbol: String(localized: "UI.Common.Symbol.Minus", defaultValue: "-"), delta: -1, compact: false)
      Text("\(value)")
        .font(.system(size: 72, weight: .bold, design: .rounded))
        .monospacedDigit()
        .frame(minWidth: 100)
        .accessibilityLabel("\(value)")
      stepButton(symbol: String(localized: "UI.Common.Symbol.Plus", defaultValue: "+"), delta: 1, compact: false)
    }
    .onChange(of: range) { _, newRange in
      let clamped = min(newRange.upperBound, max(newRange.lowerBound, value))
      if clamped != value {
        value = clamped
      }
    }
  }

  private func stepButton(symbol: String, delta: Int, compact: Bool) -> some View {
    Button {
      isFocused = false
      let next = value + delta
      value = min(range.upperBound, max(range.lowerBound, next))
    } label: {
      if compact {
        Text(symbol)
          .font(.headline)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(Color.white.opacity(0.65), in: Capsule())
      } else {
        Text(symbol)
          .font(.system(size: 32, weight: .semibold, design: .rounded))
          .frame(width: 64, height: 64)
          .background(.ultraThinMaterial, in: Circle())
          .overlay {
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
          }
      }
    }
    .buttonStyle(.plain)
    .disabled(isDisabled || (delta < 0 ? value <= range.lowerBound : value >= range.upperBound))
  }
}
