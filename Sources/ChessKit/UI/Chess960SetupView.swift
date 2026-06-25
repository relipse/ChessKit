import SwiftUI

/// Set up (and favorite) a specific Chess960 starting position, then play it.
/// Only meaningful for Fischer Random Chess.
public struct Chess960SetupView: View {
    let brand: Brand
    @ObservedObject var store: GameStore
    @ObservedObject var appearance: Appearance
    /// Launch a game from the chosen position in the given mode.
    let onPlay: (Position, GameMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var id: Int

    public init(brand: Brand, store: GameStore, appearance: Appearance = .shared,
                initialID: Int? = nil, onPlay: @escaping (Position, GameMode) -> Void) {
        self.brand = brand; self.store = store; self.appearance = appearance; self.onPlay = onPlay
        _id = State(initialValue: initialID ?? Int.random(in: 0..<960))
    }

    private var position: Position { Chess960.position(id: id) }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    BoardView(position: position, size: 260, appearance: appearance)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

                    HStack(spacing: 14) {
                        Text("Position #\(id)").font(.headline)
                        Button { store.toggleFavorite(id) } label: {
                            Image(systemName: store.isFavorite(id) ? "star.fill" : "star")
                                .foregroundStyle(store.isFavorite(id) ? .yellow : .secondary)
                        }
                    }

                    HStack(spacing: 24) {
                        Button { id = (id + 959) % 960 } label: { Image(systemName: "chevron.left.circle.fill") }
                        Button { id = Int.random(in: 0..<960) } label: {
                            Label("Shuffle", systemImage: "shuffle").font(.headline)
                        }.buttonStyle(.bordered)
                        Button { id = (id + 1) % 960 } label: { Image(systemName: "chevron.right.circle.fill") }
                    }
                    .font(.title2)

                    HStack(spacing: 12) {
                        Button { onPlay(position, .computer); dismiss() } label: {
                            Label("Play Computer", systemImage: "cpu").frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent)
                        Button { onPlay(position, .passAndPlay); dismiss() } label: {
                            Label("2 Players", systemImage: "person.2.fill").frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.bordered)
                    }
                    .padding(.horizontal)

                    if !store.favoritePositions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Favorites").font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(store.favoritePositions, id: \.self) { fav in
                                        Button { id = fav } label: {
                                            VStack(spacing: 4) {
                                                BoardView(position: Chess960.position(id: fav), size: 84,
                                                          appearance: appearance)
                                                Text("#\(fav)").font(.caption2).foregroundStyle(.secondary)
                                            }
                                            .overlay(RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(fav == id ? brand.accent : .clear, lineWidth: 2))
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.vertical, 2)
                            }
                        }
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Set Up Position")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }
}
