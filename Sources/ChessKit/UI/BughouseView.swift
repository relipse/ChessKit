import SwiftUI

/// Root for the Bughouse app: seat setup → two-board match.
public struct BughouseRootView: View {
    let brand: Brand
    @StateObject private var appearance: Appearance
    @State private var seats: [BughouseSeat: SeatPlayer]?

    public init(brand: Brand, suite: String? = nil) {
        self.brand = brand
        _appearance = StateObject(wrappedValue: Appearance(suite: suite))
    }

    public var body: some View {
        Group {
            if let seats {
                BughouseGameView(brand: brand, appearance: appearance, seats: seats,
                                 onExit: { self.seats = nil })
            } else {
                BughouseSetupView(brand: brand) { seats = $0 }
            }
        }
        .tint(brand.accent)
    }
}

/// Assign each of the four seats to a human or the computer, then start.
public struct BughouseSetupView: View {
    let brand: Brand
    let onStart: ([BughouseSeat: SeatPlayer]) -> Void
    @State private var human: [BughouseSeat: Bool] = [.b1White: true, .b1Black: false, .b2White: false, .b2Black: false]
    @State private var level = 4

    public init(brand: Brand, onStart: @escaping ([BughouseSeat: SeatPlayer]) -> Void) {
        self.brand = brand; self.onStart = onStart
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "person.2.square.stack").font(.system(size: 50)).foregroundStyle(brand.accent)
                    Text("Bughouse").font(.largeTitle.weight(.heavy))
                    Text("Two boards, two teams of two. Capture a piece and it's passed to your partner's reserve on the other board to drop in.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)

                    teamCard("Team A", seats: [.b1White, .b2Black])
                    teamCard("Team B", seats: [.b1Black, .b2White])

                    VStack(alignment: .leading) {
                        Text("Computer strength").font(.headline)
                        Picker("Level", selection: $level) { ForEach(1...10, id: \.self) { Text("Level \($0)").tag($0) } }
                        Text(Difficulty(level: level).blurb).font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal)

                    Button { onStart(buildSeats()) } label: {
                        Text("Start Match").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("New Bughouse")
        }
        .tint(brand.accent)
    }

    private func teamCard(_ title: String, seats: [BughouseSeat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(brand.accent)
            ForEach(seats) { s in
                HStack {
                    Text(s.label)
                    Spacer()
                    Picker("", selection: Binding(get: { human[s] ?? false }, set: { human[s] = $0 })) {
                        Text("Human").tag(true); Text("Computer").tag(false)
                    }.pickerStyle(.segmented).frame(width: 180)
                }
            }
        }
        .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
    }

    private func buildSeats() -> [BughouseSeat: SeatPlayer] {
        var out: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases {
            out[s] = (human[s] ?? false) ? .human : .computer(Difficulty(level: level))
        }
        return out
    }
}

/// The live two-board Bughouse match.
public struct BughouseGameView: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance
    @StateObject private var game: BughouseController
    let onExit: () -> Void

    public init(brand: Brand, appearance: Appearance = .shared,
                seats: [BughouseSeat: SeatPlayer], onExit: @escaping () -> Void) {
        self.brand = brand; self.appearance = appearance; self.onExit = onExit
        _game = StateObject(wrappedValue: BughouseController(seats: seats))
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min((geo.size.width - 24) / 2, (geo.size.height - 150) / 2)
            VStack(spacing: 8) {
                header
                if game.status.isOver { overBanner }
                HStack(alignment: .top, spacing: 10) {
                    boardColumn(0, size: side)
                    boardColumn(1, size: side)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { onExit() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)) }
            Text("Bughouse").font(.title3.weight(.bold).width(.condensed))
            Spacer()
            Button { game.newGame() } label: { Image(systemName: "arrow.counterclockwise").font(.title3) }
        }.padding(.top, 6)
    }

    private var overBanner: some View {
        Text(game.resultText).font(.headline).padding(8)
            .frame(maxWidth: .infinity).background(brand.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func boardColumn(_ b: Int, size: CGFloat) -> some View {
        let bd = game.boards[b]
        // The seat sitting at the bottom of this board's view = the human side if any, else White.
        let bottom: PieceColor = .white
        return VStack(spacing: 4) {
            Text("Board \(b + 1)").font(.caption.weight(.bold))
            pocket(b, color: .black, size: size, interactive: false)
            BoardView(position: bd.pos, flipped: bottom == .black, lastMove: bd.lastMove,
                      selected: bd.selected, targets: bd.targets,
                      checkSquare: checkSquare(bd.pos), size: size,
                      appearance: appearance,
                      onTap: { game.tap(board: b, $0) },
                      onMove: { f, t in game.move(board: b, from: f, to: t) },
                      onDropPiece: { k, sq in game.dropPiece(board: b, k, to: sq) })
            pocket(b, color: .white, size: size,
                   interactive: game.isHumanToMove(b) && bd.pos.sideToMove == .white)
            turnPill(b)
        }
    }

    private func pocket(_ b: Int, color: PieceColor, size: CGFloat, interactive: Bool) -> some View {
        PocketView(pocket: game.boards[b].pos.pockets[color] ?? Pocket(), color: color,
                   selected: color == game.boards[b].pos.sideToMove ? game.boards[b].pocketSel : nil,
                   interactive: interactive, accent: brand.accent, appearance: appearance,
                   onSelect: { game.selectPocket(board: b, $0) })
            .frame(width: size)
    }

    private func turnPill(_ b: Int) -> some View {
        let toMove = game.boards[b].pos.sideToMove
        return HStack(spacing: 4) {
            if game.thinking[b] { ProgressView().scaleEffect(0.6) }
            Text(game.isHumanToMove(b) ? "\(toMove == .white ? "White" : "Black") (you)" : "\(toMove == .white ? "White" : "Black")…")
                .font(.caption2)
        }.frame(height: 16)
    }

    private func checkSquare(_ pos: Position) -> Int? {
        pos.inCheck(pos.sideToMove) ? pos.kingSquare(pos.sideToMove) : nil
    }
}
