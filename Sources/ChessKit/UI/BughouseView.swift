import SwiftUI

/// Root for the Bughouse app: menu → seat setup → two-board match (with save/load).
public struct BughouseRootView: View {
    let brand: Brand
    let suite: String?
    @StateObject private var appearance: Appearance
    @StateObject private var store = BughouseStore()
    @State private var launch: Launch?

    enum Launch: Identifiable {
        case fresh([BughouseSeat: SeatPlayer]), restore(BughouseSave)
        var id: String { if case .restore(let s) = self { return s.id.uuidString }; return "fresh" }
    }

    public init(brand: Brand, suite: String? = nil) {
        self.brand = brand; self.suite = suite
        _appearance = StateObject(wrappedValue: Appearance(suite: suite))
    }

    public var body: some View {
        Group {
            if UserDefaults.standard.string(forKey: "shot") == "game" {
                BughouseGameView(brand: brand, appearance: appearance,
                                 controller: DemoBughouse.controller(), onExit: {})
            } else if let launch {
                gameView(launch)
            } else {
                BughouseMenuView(brand: brand, store: store, appearance: appearance,
                                 onNew: { launch = .fresh($0) }, onResume: { launch = .restore($0) })
            }
        }
        .tint(brand.accent)
    }

    @ViewBuilder private func gameView(_ l: Launch) -> some View {
        switch l {
        case .fresh(let seats):
            BughouseGameView(brand: brand, appearance: appearance,
                             controller: BughouseController(seats: seats, store: store), onExit: { launch = nil })
        case .restore(let save):
            BughouseGameView(brand: brand, appearance: appearance,
                             controller: BughouseController(seats: [:], store: store, restore: save), onExit: { launch = nil })
        }
    }
}

/// Bughouse main menu: New / Continue / Load.
struct BughouseMenuView: View {
    let brand: Brand
    @ObservedObject var store: BughouseStore
    @ObservedObject var appearance: Appearance
    let onNew: ([BughouseSeat: SeatPlayer]) -> Void
    let onResume: (BughouseSave) -> Void
    @State private var showSetup = false
    @State private var showLoad = false

    var body: some View {
        ZStack {
            Theme.heroGradient(brand.accent).opacity(0.12).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "person.2.square.stack").font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 120, height: 120)
                    .background(Theme.heroGradient(brand.accent), in: RoundedRectangle(cornerRadius: 26))
                Text("Bughouse").font(.system(.largeTitle, design: .rounded).weight(.heavy))
                Text("4-player team chess — capture and pass to your partner.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                VStack(spacing: 12) {
                    if let auto = store.autosave {
                        menuBtn("Continue", "play.fill", prominent: true) { onResume(auto) }
                    }
                    menuBtn("New Match", "plus.circle.fill", prominent: store.autosave == nil) { showSetup = true }
                    if !store.slots.isEmpty { menuBtn("Load Match", "tray.full.fill") { showLoad = true } }
                }.frame(maxWidth: 420)
                Spacer()
                Text("Kinsman Software LLC · \(MainMenuView.appVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(24)
        }
        .sheet(isPresented: $showSetup) { BughouseSetupView(brand: brand) { showSetup = false; onNew($0) } }
        .sheet(isPresented: $showLoad) {
            BughouseLoadView(brand: brand, store: store) { onResume($0) }
        }
    }

    private func menuBtn(_ t: String, _ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(t, systemImage: icon).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(prominent ? AnyShapeStyle(brand.accent) : AnyShapeStyle(.thinMaterial), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(prominent ? .white : Color.primary)
        }
    }
}

struct BughouseLoadView: View {
    let brand: Brand
    @ObservedObject var store: BughouseStore
    let onLoad: (BughouseSave) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.slots) { s in
                    Button { onLoad(s); dismiss() } label: {
                        VStack(alignment: .leading) {
                            Text(s.name).font(.headline).foregroundStyle(.primary)
                            Text("\(s.log.count) moves · \(s.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { idx in idx.map { store.slots[$0] }.forEach(store.delete) }
            }
            .navigationTitle("Load Match")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(brand.accent)
    }
}

/// Seat setup with quick presets + per-seat control.
public struct BughouseSetupView: View {
    let brand: Brand
    let onStart: ([BughouseSeat: SeatPlayer]) -> Void
    @State private var human: [Bool] = [true, false, false, false]   // by seat rawValue
    @State private var level = 4

    public init(brand: Brand, onStart: @escaping ([BughouseSeat: SeatPlayer]) -> Void) {
        self.brand = brand; self.onStart = onStart
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Two boards, two teams of two. A piece you capture is passed to your partner's reserve on the other board to drop in.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quick setup").font(.headline)
                        let cols = [GridItem(.adaptive(minimum: 150), spacing: 8)]
                        LazyVGrid(columns: cols, spacing: 8) {
                            preset("You + 3 bots", [true, false, false, false])
                            preset("You + partner, 2 bots", [true, false, false, true])
                            preset("4 humans", [true, true, true, true])
                            preset("Watch (4 bots)", [false, false, false, false])
                        }
                    }.padding(.horizontal)

                    teamCard("Team A", seats: [.b1White, .b2Black])
                    teamCard("Team B", seats: [.b1Black, .b2White])

                    if human.contains(false) {
                        VStack(alignment: .leading) {
                            Text("Computer strength").font(.headline)
                            Picker("Level", selection: $level) { ForEach(1...10, id: \.self) { Text("Level \($0)").tag($0) } }
                            Text(Difficulty(level: level).blurb).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal)
                    }

                    Button { onStart(buildSeats()) } label: {
                        Text("Start Match").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).padding(.horizontal)
                }.padding(.vertical)
            }
            .navigationTitle("New Bughouse")
        }.tint(brand.accent)
    }

    private func preset(_ title: String, _ config: [Bool]) -> some View {
        Button { human = config } label: {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(human == config ? brand.accent.opacity(0.25) : Color.primary.opacity(0.06),
                           in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func teamCard(_ title: String, seats: [BughouseSeat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(brand.accent)
            ForEach(seats) { s in
                HStack {
                    Text(s.label)
                    Spacer()
                    Picker("", selection: Binding(get: { human[s.rawValue] }, set: { human[s.rawValue] = $0 })) {
                        Text("Human").tag(true); Text("Computer").tag(false)
                    }.pickerStyle(.segmented).frame(width: 180)
                }
            }
        }.padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
    }

    private func buildSeats() -> [BughouseSeat: SeatPlayer] {
        var out: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases { out[s] = human[s.rawValue] ? .human : .computer(Difficulty(level: level)) }
        return out
    }
}

/// The live two-board Bughouse match — boards side-by-side in landscape, stacked in portrait.
public struct BughouseGameView: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance
    @StateObject private var game: BughouseController
    let onExit: () -> Void
    @State private var showSave = false
    @State private var saveName = ""
    @State private var focusMine = false

    private let overhead: CGFloat = 92   // two compact reserves + turn line

    public init(brand: Brand, appearance: Appearance = .shared,
                controller: BughouseController, onExit: @escaping () -> Void) {
        self.brand = brand; self.appearance = appearance; self.onExit = onExit
        _game = StateObject(wrappedValue: controller)
    }

    public var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let cmdH: CGFloat = game.hasHuman ? 60 : 0
            let availH = geo.size.height - cmdH - (game.status.isOver ? 40 : 0) - 4
            VStack(spacing: 4) {
                header
                if game.status.isOver { overBanner }
                boards(landscape: landscape, width: geo.size.width, availH: availH)
                Spacer(minLength: 0)
                if game.hasHuman { commandBar }
            }.padding(.horizontal, 10).frame(maxWidth: .infinity)
        }
        .alert("Save Match", isPresented: $showSave) {
            TextField("Name", text: $saveName)
            Button("Save") { game.saveSlot(name: saveName.isEmpty ? "Bughouse · \(game.moveLog.count) moves" : saveName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func boards(landscape: Bool, width: CGFloat, availH: CGFloat) -> some View {
        if landscape {
            if focusMine && game.hasHuman {
                let my = game.myBoard
                let big = min(width * 0.58, availH - overhead)
                let small = min(width * 0.34, availH - overhead)
                HStack(alignment: .center, spacing: 14) {
                    boardColumn(my, size: big)
                    boardColumn(1 - my, size: small)
                }.frame(maxWidth: .infinity)
            } else {
                let side = min((width - 28) / 2, availH - overhead)
                HStack(alignment: .center, spacing: 14) { boardColumn(0, size: side); boardColumn(1, size: side) }
                    .frame(maxWidth: .infinity)
            }
        } else {
            let side = min(width - 16, (availH - overhead * 2) / 2)
            ScrollView { VStack(spacing: 10) { boardColumn(0, size: side); boardColumn(1, size: side) } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { onExit() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)) }
            Text("Bughouse").font(.title3.weight(.bold).width(.condensed))
            Spacer()
            if game.hasHuman {
                Button { focusMine.toggle() } label: {
                    Image(systemName: focusMine ? "rectangle.split.2x1" : "rectangle.split.2x1.fill").font(.title3)
                }
            }
            Button { saveName = "Bughouse · \(game.moveLog.count) moves"; showSave = true } label: {
                Image(systemName: "square.and.arrow.down").font(.title3)
            }.disabled(game.moveLog.isEmpty)
            Button { game.newGame() } label: { Image(systemName: "arrow.counterclockwise").font(.title3) }
        }.padding(.top, 4)
    }

    private var overBanner: some View {
        Text(game.resultText).font(.headline).padding(6).frame(maxWidth: .infinity)
            .background(brand.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func boardColumn(_ b: Int, size: CGFloat) -> some View {
        let bd = game.boards[b]
        return VStack(spacing: 3) {
            pocket(b, color: .black, size: size, interactive: game.isHumanToMove(b) && bd.pos.sideToMove == .black)
            BoardView(position: bd.pos, lastMove: bd.lastMove, selected: bd.selected, targets: bd.targets,
                      checkSquare: checkSquare(bd.pos), size: size, appearance: appearance,
                      onTap: { game.tap(board: b, $0) },
                      onMove: { f, t in game.move(board: b, from: f, to: t) },
                      onDropPiece: { k, sq in game.dropPiece(board: b, k, to: sq) })
            pocket(b, color: .white, size: size, interactive: game.isHumanToMove(b) && bd.pos.sideToMove == .white)
            turnPill(b)
        }.frame(width: size)
    }

    private func pocket(_ b: Int, color: PieceColor, size: CGFloat, interactive: Bool) -> some View {
        PocketView(pocket: game.boards[b].pos.pockets[color] ?? Pocket(), color: color,
                   selected: color == game.boards[b].pos.sideToMove ? game.boards[b].pocketSel : nil,
                   interactive: interactive, accent: brand.accent, compact: true, appearance: appearance,
                   onSelect: { game.selectPocket(board: b, $0) })
            .frame(width: size)
    }

    private func turnPill(_ b: Int) -> some View {
        let toMove = game.boards[b].pos.sideToMove
        return HStack(spacing: 4) {
            Text("B\(b + 1)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            if game.thinking[b] { ProgressView().scaleEffect(0.6) }
            Text(game.isHumanToMove(b) ? "\(toMove == .white ? "White" : "Black") — your move"
                                       : "\(toMove == .white ? "White" : "Black")…")
                .font(.caption2).foregroundStyle(game.isHumanToMove(b) ? brand.accent : .secondary)
        }.frame(height: 16)
    }

    // MARK: Partner command bar

    private var commandBar: some View {
        VStack(spacing: 2) {
            if let last = game.chat.last {
                Text(last).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([PieceKind.pawn, .knight, .bishop, .rook, .queen], id: \.self) { k in
                        cmdButton(.need(k))
                    }
                    Divider().frame(height: 22)
                    cmdButton(.sit); cmdButton(.go); cmdButton(.mate)
                }.padding(.horizontal, 2)
            }
        }
        .frame(height: 54)
    }

    private func cmdButton(_ cmd: BughouseController.PartnerCommand) -> some View {
        Button { game.sendCommand(cmd) } label: {
            Text(cmd.label).font(.caption.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(brand.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(brand.accent)
        }.buttonStyle(.plain)
    }

    private func checkSquare(_ pos: Position) -> Int? {
        pos.inCheck(pos.sideToMove) ? pos.kingSquare(pos.sideToMove) : nil
    }
}

/// A populated match for App Store screenshots.
enum DemoBughouse {
    @MainActor static func controller() -> BughouseController {
        var seats: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases { seats[s] = .human }   // human so nothing auto-moves during the shot
        let g = BughouseController(seats: seats)
        func m(_ b: Int, _ a: String, _ c: String) { g.move(board: b, from: a.sq, to: c.sq) }
        // Board 1 (a capture passes a pawn to Board 2's reserve), Board 2 a Ruy López.
        m(0,"e2","e4"); m(0,"d7","d5"); m(0,"e4","d5"); m(0,"g8","f6"); m(0,"b1","c3"); m(0,"b8","c6")
        m(1,"e2","e4"); m(1,"e7","e5"); m(1,"g1","f3"); m(1,"b8","c6"); m(1,"f1","b5")
        return g
    }
}

private extension String {
    var sq: Int { let c = Array(self); return rankIndex(c[1])! * 8 + fileIndex(c[0])! }
}
