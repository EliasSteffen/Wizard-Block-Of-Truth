import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

struct EntrySheetView: View {
  let title: String
  let handSize: Int
  let players: [Player]
  let currentValues: [UUID: Int?]
  let valueLabel: String
  let accessory: AnyView?
  let allowedRange: ((UUID, [UUID: Int]) -> ClosedRange<Int>)?
  let isPlayerDisabled: ((UUID, [UUID: Int]) -> Bool)?
  let onSubmit: ([UUID: Int]) -> Error?

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
        .scrollDisabled(true)
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
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            submitError = nil
            constraintFailureText = nil

            if let err = onSubmit(valuesWithFallbacks) {
#if canImport(WizardDomain)
              if let domainErr = err as? DomainError,
                 case .constraintNotSatisfied(let constraint) = domainErr {
                constraintFailureText = constraint.showOnFailure
                return
              }
#endif
              submitError = err
              return
            } else {
              dismiss()
            }
          }
        }
      }
    }
    .wizardBackground()
    .alert("Invalid input", isPresented: Binding(
      get: { submitError != nil },
      set: { newValue in if !newValue { submitError = nil } }
    )) {
      Button("OK", role: .cancel) { submitError = nil }
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

  private var sumBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let constraintFailureText {
        Text(constraintFailureText)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.red)
      }

      HStack {
        Text("Sum")
        Spacer()
        Text("\(sum)")
          .foregroundStyle(sum == handSize ? .primary : .secondary)
      }
    }
    .font(.subheadline.weight(.semibold))
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(sumBarBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var sumBarBackground: Color {
#if os(iOS)
    return Color(uiColor: .secondarySystemGroupedBackground)
#else
    return Color.black.opacity(0.10)
#endif
  }

  private func currentValue(for playerId: UUID) -> Int {
    // currentValues[playerId] is Int?? because the dictionary value is optional (Int?).
    // Treat nil as 0 for editing convenience.
    return (currentValues[playerId] ?? nil) ?? 0
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
        pill("-")
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
        pill("+")
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

