import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

struct EntrySheetView: View {
  struct SumValidation {
    enum Rule {
      case equals
      case notEquals
    }

    let expectedSum: Int
    let rule: Rule
    let failureMessageKey: String
    let failureMessageFallback: String
  }

  let title: LocalizedStringKey
  let handSize: Int
  let players: [Player]
  let currentValues: [UUID: Int?]
  let valueLabel: String
  let accessory: AnyView?
  let sumValidation: SumValidation?
  let showPositiveSumState: Bool
  let allowedRange: ((UUID, [UUID: Int]) -> ClosedRange<Int>)?
  let isPlayerDisabled: ((UUID, [UUID: Int]) -> Bool)?
  let onSubmit: ([UUID: Int]) -> Error?

  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue
  @Environment(\.dismiss) private var dismiss

  @State private var values: [UUID: Int] = [:]
  @State private var submitError: Error?
  @State private var constraintFailureText: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let accessory {
          accessory
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        List {
          ForEach(players, id: \.id) { player in
            HStack {
              Text(player.name)
                .lineLimit(1)
                .truncationMode(.tail)
                // Fixed name column so steppers stay aligned across rows.
                .frame(width: 140, alignment: .leading)
              Spacer()
              StepperPills(
                value: Binding(
                  get: { values[player.id, default: currentValue(for: player.id)] },
                  set: {
                    constraintFailureText = nil
                    let current = valuesWithFallbacks
                    let allowed = allowedRange?(player.id, current) ?? (0...handSize)
                    values[player.id] = min(allowed.upperBound, max(allowed.lowerBound, $0))
                  }
                ),
                range: allowedRange?(player.id, valuesWithFallbacks) ?? (0...handSize),
                isDisabled: isPlayerDisabled?(player.id, valuesWithFallbacks) ?? false
              )
            }
          }
        }
#if os(iOS)
        .scrollContentBackground(.hidden)
#endif
        .onTapGesture {
          // Any tap inside the list clears the failure hint.
          constraintFailureText = nil
        }

        sumBar
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 16)
      }
      .navigationTitle(title)
#if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
#endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("UI.Common.Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("UI.Common.Done") {
            submitError = nil
            constraintFailureText = nil

            if let err = onSubmit(valuesWithFallbacks) {
#if canImport(WizardDomain)
              if let domainErr = err as? DomainError,
                 case .constraintNotSatisfied(let constraint) = domainErr {
                constraintFailureText = localizedConstraintFailure(constraint)
                return
              }
#endif
              submitError = err
              return
            } else {
              dismiss()
            }
          }
          .disabled(isLiveSumValidationEnabled && !isSumValid)
        }
      }
    }
    .wizardBackground()
    .alert("UI.EntrySheet.InvalidInput.Title", isPresented: Binding(
      get: { submitError != nil },
      set: { newValue in if !newValue { submitError = nil } }
    )) {
      Button("UI.Common.OK", role: .cancel) { submitError = nil }
    } message: {
      Text(submitError?.localizedDescription ?? "")
    }
    .onAppear {
      // Seed values so the sheet is always fully specified.
      for p in players {
        if let v = currentValues[p.id] ?? nil {
          values[p.id] = v
        } else {
          values[p.id] = 0
        }
      }
    }
  }

  private var valuesWithFallbacks: [UUID: Int] {
    var out: [UUID: Int] = [:]
    out.reserveCapacity(players.count)
    for p in players {
      out[p.id] = values[p.id, default: currentValue(for: p.id)]
    }
    return out
  }

  private var sum: Int {
    valuesWithFallbacks.values.reduce(0, +)
  }

  private var isLiveSumValidationEnabled: Bool {
    sumValidation != nil
  }

  private var shouldHighlightPositiveState: Bool {
    isLiveSumValidationEnabled || showPositiveSumState
  }

  private var isSumValid: Bool {
    guard let sumValidation else { return true }
    switch sumValidation.rule {
    case .equals:
      return sum == sumValidation.expectedSum
    case .notEquals:
      return sum != sumValidation.expectedSum
    }
  }

  private var liveValidationMessage: String? {
    guard isLiveSumValidationEnabled, !isSumValid else { return nil }
    guard let sumValidation else { return constraintFailureText }
    return constraintFailureText ?? AppLocalization.string(sumValidation.failureMessageKey, languageCode: currentLanguageCode, fallback: sumValidation.failureMessageFallback)
  }

  private var sumValueText: String {
    guard let sumValidation else { return "\(sum)" }
    switch sumValidation.rule {
    case .equals:
      return "\(sum)/\(sumValidation.expectedSum)"
    case .notEquals:
      return "\(sum)"
    }
  }

  private var sumBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let liveValidationMessage {
        Text(liveValidationMessage)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.red)
      } else if let constraintFailureText {
        Text(constraintFailureText)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.red)
      }

      HStack {
        Text("UI.EntrySheet.Sum.Label")
        Spacer()
        Text(sumValueText)
          .foregroundStyle(sumValueForegroundStyle)
      }
    }
    .font(.subheadline.weight(.semibold))
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(sumBarBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(sumBarBorderColor, lineWidth: shouldHighlightPositiveState ? 1 : 0)
    }
  }

  private var sumBarBackground: Color {
    if isLiveSumValidationEnabled {
#if os(iOS)
      return Color(uiColor: isSumValid ? .systemGreen.withAlphaComponent(0.22) : .systemRed.withAlphaComponent(0.22))
#else
      return isSumValid ? Color.green.opacity(0.22) : Color.red.opacity(0.22)
#endif
    }

    if showPositiveSumState {
#if os(iOS)
      return Color(uiColor: .systemGreen.withAlphaComponent(0.22))
#else
      return Color.green.opacity(0.22)
#endif
    }

#if os(iOS)
    return Color(uiColor: .secondarySystemGroupedBackground)
#else
    return Color.black.opacity(0.10)
#endif
  }

  private var sumValueForegroundStyle: Color {
    if isLiveSumValidationEnabled {
      return isSumValid ? .green : .red
    }

    if showPositiveSumState {
      return .green
    }

    guard isLiveSumValidationEnabled else {
      return sum == handSize ? .primary : .secondary
    }
    return isSumValid ? .green : .red
  }

  private var sumBarBorderColor: Color {
    if isLiveSumValidationEnabled {
      return isSumValid ? .green.opacity(0.45) : .red.opacity(0.55)
    }

    if showPositiveSumState {
      return .green.opacity(0.45)
    }

    return .clear
  }

  private func currentValue(for playerId: UUID) -> Int {
    // currentValues[playerId] is Int?? because the dictionary value is optional (Int?).
    // Treat nil as 0 for editing convenience.
    return (currentValues[playerId] ?? nil) ?? 0
  }

#if canImport(WizardDomain)
  private func localizedConstraintFailure(_ constraint: Constraint) -> String {
    let key: String
    let fallback: String

    switch constraint {
    case .game(let gameConstraint):
      key = gameConstraint.showOnFailureKey
      fallback = gameConstraint.showOnFailure
    case .round(let roundConstraint):
      key = roundConstraint.showOnFailureKey
      fallback = roundConstraint.showOnFailure
    }

    return AppLocalization.string(key, languageCode: currentLanguageCode, fallback: fallback)
  }
#endif

  private var currentLanguageCode: String? {
    let selectedLanguage = AppLanguage(rawValue: appLanguageRaw) ?? .system
    return selectedLanguage == .system ? nil : selectedLanguage.rawValue
  }
}

private struct StepperPills: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let isDisabled: Bool

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Button {
        isFocused = false
        value = max(range.lowerBound, value - 1)
      } label: {
        pill(String(localized: "UI.Common.Symbol.Minus", defaultValue: "-"))
      }
      .buttonStyle(.plain)
      .disabled(isDisabled || value <= range.lowerBound)

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

      Button {
        isFocused = false
        value = min(range.upperBound, value + 1)
      } label: {
        pill(String(localized: "UI.Common.Symbol.Plus", defaultValue: "+"))
      }
      .buttonStyle(.plain)
      .disabled(isDisabled || value >= range.upperBound)
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

  private func pill(_ text: String) -> some View {
    Text(text)
      .font(.headline)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Color.white.opacity(0.65), in: Capsule())
  }
}

