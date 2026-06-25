import SwiftUI

/// A board editor: place/remove pieces, choose the side to move, then play the position
/// (vs computer or pass-and-play). Used by the plain Chess app's "Set Up Pieces".
public struct PositionSetupView: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance
    /// Launch a game from the built position in the given mode.
    let onPlay: (Position, GameMode) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var squares: [Piece?] = Position.standard.squares
    @State private var sideToMove: PieceColor = .white
    @State private var brush: Brush = .erase

    enum Brush: Equatable { case piece(Piece), erase }

    public init(brand: Brand, appearance: Appearance = .shared,
                onPlay: @escaping (Position, GameMode) -> Void) {
        self.brand = brand; self.appearance = appearance; self.onPlay = onPlay
    }

    /// The position being edited, with castling rights inferred from king/rook home squares.
    private var position: Position {
        var p = Position(squares: squares, sideToMove: sideToMove, castling: [], enPassant: nil)
        var rights: Set<Character> = []
        if p.squares[4]?.kind == .king, p.squares[4]?.color == .white {
            if p.squares[7]?.kind == .rook, p.squares[7]?.color == .white { rights.insert("K") }
            if p.squares[0]?.kind == .rook, p.squares[0]?.color == .white { rights.insert("Q") }
        }
        if p.squares[60]?.kind == .king, p.squares[60]?.color == .black {
            if p.squares[63]?.kind == .rook, p.squares[63]?.color == .black { rights.insert("k") }
            if p.squares[56]?.kind == .rook, p.squares[56]?.color == .black { rights.insert("q") }
        }
        p.castling = rights
        return p
    }

    private var kingsOK: Bool {
        squares.compactMap { $0 }.filter { $0.kind == .king && $0.color == .white }.count == 1 &&
        squares.compactMap { $0 }.filter { $0.kind == .king && $0.color == .black }.count == 1
    }
    private var sideInCheckToMoveIntoIllegal: Bool {
        // The side NOT to move must not already be in check (you can't move into a position
        // where the opponent's king is capturable).
        position.inCheck(sideToMove.opposite)
    }
    private var playable: Bool { kingsOK && !sideInCheckToMoveIntoIllegal }

    public var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let size = min(geo.size.width - 24, 360)
                ScrollView {
                    VStack(spacing: 14) {
                        BoardView(position: position, size: size, appearance: appearance,
                                  onTap: { tap($0) })
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

                        palette(white: true, size: size)
                        palette(white: false, size: size)

                        Picker("Side to move", selection: $sideToMove) {
                            Text("White to move").tag(PieceColor.white)
                            Text("Black to move").tag(PieceColor.black)
                        }.pickerStyle(.segmented).padding(.horizontal)

                        HStack(spacing: 10) {
                            Button { squares = [Piece?](repeating: nil, count: 64) } label: {
                                Label("Clear", systemImage: "trash").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                            Button { squares = Position.standard.squares; sideToMove = .white } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                        }.padding(.horizontal)

                        if !kingsOK {
                            Text("Place exactly one white king and one black king.")
                                .font(.caption).foregroundStyle(.orange)
                        } else if sideInCheckToMoveIntoIllegal {
                            Text("Illegal: the side not to move is in check.")
                                .font(.caption).foregroundStyle(.orange)
                        }

                        HStack(spacing: 12) {
                            Button { onPlay(position, .computer); dismiss() } label: {
                                Label("Play Computer", systemImage: "cpu").frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.borderedProminent).disabled(!playable)
                            Button { onPlay(position, .passAndPlay); dismiss() } label: {
                                Label("2 Players", systemImage: "person.2.fill").frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.bordered).disabled(!playable)
                        }.padding(.horizontal)
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Set Up Pieces")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }

    private func tap(_ sq: Int) {
        switch brush {
        case .erase: squares[sq] = nil
        case .piece(let p): squares[sq] = p
        }
    }

    @ViewBuilder
    private func palette(white: Bool, size: CGFloat) -> some View {
        let color: PieceColor = white ? .white : .black
        let kinds: [PieceKind] = [.king, .queen, .rook, .bishop, .knight, .pawn]
        HStack(spacing: 6) {
            ForEach(kinds, id: \.self) { kind in
                let piece = Piece(color: color, kind: kind)
                Button { brush = .piece(piece) } label: {
                    PieceGlyph(piece: piece, size: 34, appearance: appearance)
                        .frame(width: 40, height: 40)
                        .background((brush == .piece(piece) ? brand.accent.opacity(0.25) : Color.primary.opacity(0.05)),
                                   in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Button { brush = .erase } label: {
                Image(systemName: "eraser.fill").font(.title3)
                    .frame(width: 40, height: 40)
                    .background((brush == .erase ? brand.accent.opacity(0.25) : Color.primary.opacity(0.05)),
                               in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).opacity(white ? 1 : 0)   // one eraser, on the top row
        }
        .frame(maxWidth: .infinity)
    }
}
