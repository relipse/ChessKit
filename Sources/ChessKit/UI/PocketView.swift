import SwiftUI

extension View {
    /// Conditionally apply a view transform (used to gate `.draggable` on interactivity).
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// The Crazyhouse reserve bar for one side: tappable piece chips with counts.
public struct PocketView: View {
    public let pocket: Pocket
    public let color: PieceColor
    public var selected: PieceKind?
    public var interactive: Bool
    public var accent: Color
    public var onSelect: ((PieceKind) -> Void)?
    @ObservedObject private var appearance: Appearance

    public var compact = false

    public init(pocket: Pocket, color: PieceColor, selected: PieceKind? = nil,
                interactive: Bool, accent: Color, compact: Bool = false, appearance: Appearance = .shared,
                onSelect: ((PieceKind) -> Void)? = nil) {
        self.pocket = pocket; self.color = color; self.selected = selected
        self.interactive = interactive; self.accent = accent; self.compact = compact
        self.appearance = appearance; self.onSelect = onSelect
    }

    private var dim: CGFloat { compact ? 30 : 46 }

    private let order: [PieceKind] = [.pawn, .knight, .bishop, .rook, .queen]

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(order, id: \.self) { kind in
                let n = pocket.count(kind)
                if n > 0 {
                    Button { onSelect?(kind) } label: { chip(kind, n) }
                        .buttonStyle(.plain)
                        .disabled(!interactive)
                        .if(interactive) { view in
                            view.draggable(String(kind.rawValue)) {
                                PieceGlyph(piece: Piece(color: color, kind: kind), size: 44,
                                           appearance: appearance)
                                    .frame(width: 50, height: 50)
                            }
                        }
                }
            }
            if pocket.isEmpty {
                Text("Reserve empty").font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 6 : 10).padding(.vertical, compact ? 3 : 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func chip(_ kind: PieceKind, _ n: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(selected == kind ? accent.opacity(0.25) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected == kind ? accent : Color.clear, lineWidth: 2))
                .frame(width: dim - 4, height: dim - 4)
            PieceGlyph(piece: Piece(color: color, kind: kind), size: dim - 8, appearance: appearance)
                .frame(width: dim - 4, height: dim - 4)
            if n > 1 {
                Text("\(n)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(compact ? 2 : 3).background(accent, in: Circle())
                    .offset(x: compact ? 4 : 6, y: compact ? -4 : -6)
            }
        }
        .frame(width: dim, height: dim)
    }
}
