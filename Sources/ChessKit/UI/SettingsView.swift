import SwiftUI

/// Board appearance + difficulty settings, shared by every app.
public struct SettingsView: View {
    @ObservedObject var game: GameController
    let brand: Brand
    @ObservedObject var appearance: Appearance
    @Environment(\.dismiss) private var dismiss

    public init(game: GameController, brand: Brand, appearance: Appearance = .shared) {
        self.game = game; self.brand = brand; self.appearance = appearance
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Difficulty") {
                    Picker("Computer strength", selection: Binding(
                        get: { game.difficulty },
                        set: { game.difficulty = $0 })) {
                        ForEach(Difficulty.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("Takes effect on your next New Game.").font(.caption).foregroundStyle(.secondary)
                }
                AppearanceSections(brand: brand, appearance: appearance)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }
}

/// Appearance-only settings (board theme, pieces, display) — usable with or without a game.
public struct AppearanceSettingsView: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance
    @Environment(\.dismiss) private var dismiss

    public init(brand: Brand, appearance: Appearance = .shared) {
        self.brand = brand; self.appearance = appearance
    }

    public var body: some View {
        NavigationStack {
            Form { AppearanceSections(brand: brand, appearance: appearance) }
                .navigationTitle("Appearance")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }
}

/// The shared Board / Pieces / Display form sections.
struct AppearanceSections: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance

    var body: some View {
        Section("Board") {
            let cols = [GridItem(.adaptive(minimum: 64), spacing: 10)]
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(BoardTheme.all) { theme in swatch(theme) }
            }.padding(.vertical, 4)
        }
        Section("Pieces") {
            Picker("Piece set", selection: $appearance.pieceSetID) {
                ForEach(PieceSet.all) { Text($0.name).tag($0.id) }
            }
        }
        Section("Display") {
            Toggle("Coordinates", isOn: $appearance.showCoordinates)
            Toggle("Legal-move dots", isOn: $appearance.showLegalDots)
        }
    }

    private func swatch(_ theme: BoardTheme) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    Rectangle().fill(i % 2 == 0 ? theme.light : theme.dark)
                }
            }
            .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(appearance.boardThemeID == theme.id ? brand.accent : .clear, lineWidth: 3))
            Text(theme.name).font(.caption2).foregroundStyle(.secondary)
        }
        .onTapGesture { appearance.boardThemeID = theme.id }
    }
}

/// New-game options: pick a side and difficulty, then start.
public struct NewGameSheet: View {
    @ObservedObject var game: GameController
    let brand: Brand
    @Environment(\.dismiss) private var dismiss
    @State private var color: PieceColor
    @State private var difficulty: Difficulty

    public init(game: GameController, brand: Brand) {
        self.game = game; self.brand = brand
        _color = State(initialValue: game.humanColor)
        _difficulty = State(initialValue: game.difficulty)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Play as") {
                    Picker("Side", selection: $color) {
                        Text("White").tag(PieceColor.white)
                        Text("Black").tag(PieceColor.black)
                    }.pickerStyle(.segmented)
                }
                Section("Difficulty") {
                    Picker("Strength", selection: $difficulty) {
                        ForEach(Difficulty.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section {
                    Button {
                        game.newGame(humanColor: color, difficulty: difficulty)
                        dismiss()
                    } label: {
                        Text("Start Game").frame(maxWidth: .infinity).font(.headline)
                    }.buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("New \(brand.title) Game")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(brand.accent)
    }
}
