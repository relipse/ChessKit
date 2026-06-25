import SwiftUI

/// An interactive chessboard. Renders a `Position`, highlights the last move, the
/// selected square, legal targets and check, and reports taps back to the caller.
/// Set `hiddenColor` to fog out one side's pieces (Kriegspiel).
public struct BoardView: View {
    public let position: Position
    public var flipped: Bool = false
    public var lastMove: (from: Int, to: Int)?
    public var selected: Int?
    public var targets: Set<Int> = []
    /// Pieces to pulse-highlight as a hint (e.g. the pieces that must capture in Losers).
    public var hintSquares: Set<Int> = []
    public var checkSquare: Int?
    /// Pieces of this colour are hidden from view (fog of war). nil → show everything.
    public var hiddenColor: PieceColor?
    public var size: CGFloat
    /// Optional per-board colour scheme override (used by Bughouse to give each board its own look).
    public var boardTheme: BoardTheme?
    public var onTap: ((Int) -> Void)?
    /// Called when a piece is dragged from one square and dropped on another.
    public var onMove: ((Int, Int) -> Void)?
    /// Called when a reserve piece (Crazyhouse) is dragged from the pocket onto a square.
    public var onDropPiece: ((PieceKind, Int) -> Void)?

    @ObservedObject private var appearance: Appearance

    // Drag-and-drop state.
    @State private var dragFrom: Int?
    @State private var dragLocation: CGPoint = .zero
    @State private var dragOver: Int?

    public init(position: Position, flipped: Bool = false,
                lastMove: (from: Int, to: Int)? = nil, selected: Int? = nil,
                targets: Set<Int> = [], hintSquares: Set<Int> = [], checkSquare: Int? = nil,
                hiddenColor: PieceColor? = nil,
                size: CGFloat, boardTheme: BoardTheme? = nil, appearance: Appearance = .shared,
                onTap: ((Int) -> Void)? = nil, onMove: ((Int, Int) -> Void)? = nil,
                onDropPiece: ((PieceKind, Int) -> Void)? = nil) {
        self.position = position
        self.flipped = flipped
        self.lastMove = lastMove
        self.selected = selected
        self.targets = targets
        self.hintSquares = hintSquares
        self.checkSquare = checkSquare
        self.hiddenColor = hiddenColor
        self.size = size
        self.boardTheme = boardTheme
        self.appearance = appearance
        self.onTap = onTap
        self.onMove = onMove
        self.onDropPiece = onDropPiece
    }

    /// Map a point in board-local coordinates to a square index (respecting flip).
    private func square(at p: CGPoint) -> Int? {
        let cell = size / 8
        guard p.x >= 0, p.y >= 0, p.x < size, p.y < size else { return nil }
        let displayCol = min(7, max(0, Int(p.x / cell)))
        let displayRow = min(7, max(0, Int(p.y / cell)))
        let file = flipped ? (7 - displayCol) : displayCol
        let rank = flipped ? displayRow : (7 - displayRow)
        return rank * 8 + file
    }

    private var scheme: BoardTheme { boardTheme ?? appearance.theme }
    private var light: Color { scheme.light }
    private var dark: Color { scheme.dark }
    private var highlight: Color { scheme.highlight }

    public var body: some View {
        let sq = size / 8
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { displayRow in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { displayCol in
                            cell(displayRow: displayRow, displayCol: displayCol, sq: sq)
                        }
                    }
                }
            }
            // The lifted piece follows the finger during a drag.
            if let from = dragFrom, let piece = position.squares[from], piece.color != hiddenColor {
                PieceGlyph(piece: piece, size: sq * 1.15, appearance: appearance)
                    .frame(width: sq * 1.15, height: sq * 1.15)
                    .position(dragLocation)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .dropDestination(for: String.self) { items, location in
            guard let code = items.first, let ch = code.first,
                  let kind = PieceKind(rawValue: ch), let sq = square(at: location) else { return false }
            onDropPiece?(kind, sq)
            return true
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragFrom == nil {
                    guard let from = square(at: value.startLocation),
                          let p = position.squares[from], p.color != hiddenColor else { return }
                    dragFrom = from
                    onTap?(from)   // select so legal targets light up
                }
                dragLocation = value.location
                dragOver = square(at: value.location)
            }
            .onEnded { value in
                defer { dragFrom = nil; dragOver = nil }
                guard let from = dragFrom, let to = square(at: value.location), from != to else { return }
                onMove?(from, to)
            }
    }

    @ViewBuilder
    private func cell(displayRow: Int, displayCol: Int, sq: CGFloat) -> some View {
        let file = flipped ? (7 - displayCol) : displayCol
        let rank = flipped ? displayRow : (7 - displayRow)
        let i = rank * 8 + file
        let isLight = (file + rank) % 2 == 1
        let isMoveSquare = (i == lastMove?.from || i == lastMove?.to)
        let piece = position.squares[i]
        let visible = piece != nil && piece?.color != hiddenColor

        ZStack {
            Rectangle().fill(isLight ? light : dark)
            if isMoveSquare { Rectangle().fill(highlight) }
            if i == selected { Rectangle().fill(Color.green.opacity(0.45)) }
            if i == checkSquare { Rectangle().fill(Color.red.opacity(0.45)) }
            if i == dragOver, dragFrom != nil, i != dragFrom {
                Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: sq * 0.06)
            }
            if hintSquares.contains(i) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.orange, lineWidth: sq * 0.09)
            }

            if let piece, visible, i != dragFrom {
                PieceGlyph(piece: piece, size: sq, appearance: appearance)
            }
            if appearance.showLegalDots, targets.contains(i) {
                if piece == nil {
                    Circle().fill(Color.black.opacity(0.22)).frame(width: sq * 0.32, height: sq * 0.32)
                } else {
                    Circle().strokeBorder(Color.black.opacity(0.28), lineWidth: sq * 0.07)
                        .frame(width: sq * 0.92, height: sq * 0.92)
                }
            }
            if appearance.showCoordinates {
                coordinates(file: file, rank: rank, col: displayCol, row: displayRow, sq: sq, isLight: isLight)
            }
        }
        .frame(width: sq, height: sq)
        .contentShape(Rectangle())
        .onTapGesture { onTap?(i) }
    }

    @ViewBuilder
    private func coordinates(file: Int, rank: Int, col: Int, row: Int, sq: CGFloat, isLight: Bool) -> some View {
        let textColor = isLight ? dark : light
        ZStack {
            if col == 0 {
                Text("\(rank + 1)")
                    .font(.system(size: sq * 0.18, weight: .bold)).foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(2)
            }
            if row == 7 {
                Text(String(UnicodeScalar(UInt8(97 + file))))
                    .font(.system(size: sq * 0.18, weight: .bold)).foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(2)
            }
        }
    }
}

/// A single piece rendered with the selected piece set (bundled artwork or Unicode glyphs).
public struct PieceGlyph: View {
    public let piece: Piece
    public let size: CGFloat
    @ObservedObject private var appearance: Appearance

    public init(piece: Piece, size: CGFloat, appearance: Appearance = .shared) {
        self.piece = piece
        self.size = size
        self.appearance = appearance
    }

    private var glyph: String {
        switch piece.kind {
        case .king: return "\u{265A}"; case .queen: return "\u{265B}"
        case .rook: return "\u{265C}"; case .bishop: return "\u{265D}"
        case .knight: return "\u{265E}"; case .pawn: return "\u{265F}"
        }
    }

    public var body: some View {
        if let name = appearance.pieceSet.assetName(color: piece.color, kind: piece.kind) {
            Image(name, bundle: .module)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size * 0.88, height: size * 0.88)
        } else {
            ZStack {
                ForEach(0..<4, id: \.self) { idx in
                    let dx: CGFloat = idx == 0 ? -1 : (idx == 1 ? 1 : 0)
                    let dy: CGFloat = idx == 2 ? -1 : (idx == 3 ? 1 : 0)
                    Text(glyph).font(.system(size: size * 0.74))
                        .foregroundStyle(piece.color == .white ? .black : Color(white: 0.7))
                        .offset(x: dx, y: dy)
                }
                Text(glyph).font(.system(size: size * 0.74))
                    .foregroundStyle(piece.color == .white ? .white : .black)
            }
        }
    }
}
