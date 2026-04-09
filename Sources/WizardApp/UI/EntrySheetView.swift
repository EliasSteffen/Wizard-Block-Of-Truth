import SwiftUI

struct EntrySheetView: View {
  let title: String
  let handSize: Int
  let players: [Player]
  let currentValues: [UUID: Int?]
  let valueLabel: String
  let onSubmit: ([UUID: Int]) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var values: [UUID: Int] = [:]

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(players, id: \.id) { player in
            HStack {
              Text(player.name)
              Spacer()
              Picker(valueLabel, selection: Binding(
                get: { values[player.id, default: currentValue(for: player.id)] },
                set: { values[player.id] = $0 }
              )) {
                ForEach(0...handSize, id: \.self) { v in
                  Text("\(v)").tag(v)
                }
              }
              .pickerStyle(.menu)
              .frame(minWidth: 64)
            }
          }
        } header: {
          Text("Hand size: \(handSize)")
        } footer: {
          Text("Pick values from 0 to \(handSize).")
        }

        Section {
          HStack {
            Text("Sum")
            Spacer()
            Text("\(sum)")
              .foregroundStyle(sum == handSize ? .primary : .secondary)
          }
        }
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
            onSubmit(valuesWithFallbacks)
            dismiss()
          }
        }
      }
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

  private func currentValue(for playerId: UUID) -> Int {
    // currentValues[playerId] is Int?? because the dictionary value is optional (Int?).
    // Treat nil as 0 for editing convenience.
    return (currentValues[playerId] ?? nil) ?? 0
  }
}

