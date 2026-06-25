import SwiftUI
import StoreKit

/// Root for the Bughouse app: menu → seat setup → two-board match (with save/load).
public struct BughouseRootView: View {
    let brand: Brand
    let suite: String?
    @StateObject private var appearance: Appearance
    @StateObject private var store = BughouseStore()
    @State private var launch: Launch?

    enum Launch: Identifiable {
        case fresh([BughouseSeat: SeatPlayer], Double, Double), restore(BughouseSave)
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
                                 onNew: { launch = .fresh($0, $1, $2) }, onResume: { launch = .restore($0) })
            }
        }
        .tint(brand.accent)
    }

    @ViewBuilder private func gameView(_ l: Launch) -> some View {
        switch l {
        case .fresh(let seats, let base, let inc):
            BughouseGameView(brand: brand, appearance: appearance,
                             controller: BughouseController(seats: seats, store: store, baseTime: base, increment: inc),
                             onExit: { launch = nil })
        case .restore(let save):
            BughouseGameView(brand: brand, appearance: appearance,
                             controller: BughouseController(seats: [:], store: store, restore: save), onExit: { launch = nil })
        }
    }
}

/// Full Bughouse main menu — same shape as the other chess apps (thematic).
struct BughouseMenuView: View {
    let brand: Brand
    @ObservedObject var store: BughouseStore
    @ObservedObject var appearance: Appearance
    let onNew: ([BughouseSeat: SeatPlayer], Double, Double) -> Void
    let onResume: (BughouseSave) -> Void

    @State private var showSetup = false
    @State private var showLoad = false
    @State private var showMore = false
    @State private var showRules = false
    @State private var showAppearance = false
    @State private var showAbout = false
    @Environment(\.requestReview) private var requestReview
    @AppStorage("ck.launchCount") private var launchCount = 0
    @AppStorage("ck.didPromptReview") private var didPromptReview = false

    var body: some View {
        ZStack {
            Theme.heroGradient(brand.accent).opacity(0.12).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: brand.systemImage).font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 116, height: 116)
                    .background(Theme.heroGradient(brand.accent), in: RoundedRectangle(cornerRadius: 26))
                Text("Bughouse Chess").font(.system(.largeTitle, design: .rounded).weight(.heavy))
                Text("4-player team chess — capture and pass to your partner.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                VStack(spacing: 12) {
                    if let auto = store.autosave {
                        btn("Continue", "play.fill", prominent: true) { onResume(auto) }
                        Text("\(auto.log.count) moves").font(.caption).foregroundStyle(.secondary)
                    }
                    btn("New Match", "plus.circle.fill", prominent: store.autosave == nil) { showSetup = true }
                    if !store.slots.isEmpty { btn("Load Match", "tray.full.fill") { showLoad = true } }
                    btn("How to Play", "book.fill") { showRules = true }
                    btn("Appearance", "paintpalette.fill") { showAppearance = true }
                    HStack(spacing: 12) {
                        ShareLink(item: brand.appStoreURL, message: Text("Play Bughouse Chess — 4-player team chess!")) {
                            Label("Share", systemImage: "square.and.arrow.up").font(.subheadline)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        compact("Rate", "star.fill") { requestReview() }
                        compact("About", "info.circle.fill") { showAbout = true }
                    }
                    btn("More Chess Games", "square.grid.2x2.fill") { showMore = true }   // always last
                }.frame(maxWidth: 420)
                Spacer()
                Text("4-player · Offline · Kinsman Software LLC\n\(MainMenuView.appVersion)")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24)
        }
        .onAppear {
            launchCount += 1
            if launchCount >= 10 && !didPromptReview { didPromptReview = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { requestReview() } }
        }
        .sheet(isPresented: $showSetup) { BughouseSetupView(brand: brand) { s, base, inc in showSetup = false; onNew(s, base, inc) } }
        .sheet(isPresented: $showLoad) { BughouseLoadView(brand: brand, store: store) { onResume($0) } }
        .sheet(isPresented: $showMore) { MoreGamesView(currentAppStoreID: brand.appStoreID, brand: brand) }
        .sheet(isPresented: $showRules) { BughouseRulesView(brand: brand) }
        .sheet(isPresented: $showAppearance) { BughouseAppearanceView(brand: brand, appearance: appearance) }
        .sheet(isPresented: $showAbout) { AboutView(brand: brand) }
    }

    private func btn(_ t: String, _ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(t, systemImage: icon).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(prominent ? AnyShapeStyle(brand.accent) : AnyShapeStyle(.thinMaterial), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(prominent ? .white : Color.primary)
        }
    }
    private func compact(_ t: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(t, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

/// How to play Bughouse.
struct BughouseRulesView: View {
    let brand: Brand
    @Environment(\.dismiss) private var dismiss
    private let rules = [
        "Two boards, two teams of two. Partners play opposite colours on opposite boards.",
        "When you capture a piece, it's passed to your partner's reserve on the other board.",
        "On your turn you can move, or drop a reserve piece onto an empty square (pawns not on the back rank).",
        "If either board is checkmated, that team wins the whole match.",
        "Talk to your partner with the quick phrases — “Send me a knight!”, “Sit!”, “Go!” — they even nudge a computer partner.",
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Bughouse").font(.title3.weight(.bold)).foregroundStyle(brand.accent)
                    ForEach(rules, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").font(.callout) }
                }.padding(20)
            }
            .navigationTitle("How to Play")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(brand.accent)
    }
}

/// Appearance — shared pieces/display + a separate colour scheme for each board.
struct BughouseAppearanceView: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance
    @AppStorage("bug.board1Theme") var board1 = "brown"
    @AppStorage("bug.board2Theme") var board2 = "green"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Board 1 colours") { themeGrid(selected: $board1) }
                Section("Board 2 colours") { themeGrid(selected: $board2) }
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
            .navigationTitle("Appearance")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(brand.accent)
    }

    private func themeGrid(selected: Binding<String>) -> some View {
        let cols = [GridItem(.adaptive(minimum: 60), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(BoardTheme.all) { t in
                VStack(spacing: 3) {
                    HStack(spacing: 0) { ForEach(0..<4, id: \.self) { i in Rectangle().fill(i % 2 == 0 ? t.light : t.dark) } }
                        .frame(height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected.wrappedValue == t.id ? brand.accent : .clear, lineWidth: 3))
                    Text(t.name).font(.caption2).foregroundStyle(.secondary)
                }.onTapGesture { selected.wrappedValue = t.id }
            }
        }.padding(.vertical, 4)
    }
}

/// Seat setup with quick presets + per-seat control.
public struct BughouseSetupView: View {
    let brand: Brand
    let onStart: ([BughouseSeat: SeatPlayer], Double, Double) -> Void
    @State private var human: [Bool] = [true, false, false, false]
    @State private var level = 4
    @State private var timeControl = 2   // index into timeControls

    // Traditional bughouse time controls (base seconds, increment seconds).
    private let timeControls: [(label: String, base: Double, inc: Double)] = [
        ("1|0 — bullet", 60, 0), ("2|0 — classic bug", 120, 0),
        ("3|2", 180, 2), ("5|0", 300, 0), ("10|0 — relaxed", 600, 0),
    ]

    public init(brand: Brand, onStart: @escaping ([BughouseSeat: SeatPlayer], Double, Double) -> Void) {
        self.brand = brand; self.onStart = onStart
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("A piece you capture is passed to your partner's reserve on the other board to drop in.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quick setup").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                            preset("You + 3 bots", [true, false, false, false])
                            preset("You + partner, 2 bots", [true, false, false, true])
                            preset("4 humans", [true, true, true, true])
                            preset("Watch (4 bots)", [false, false, false, false])
                        }
                    }.padding(.horizontal)
                    teamCard("Team A", seats: [.b1White, .b2Black])
                    teamCard("Team B", seats: [.b1Black, .b2White])
                    VStack(alignment: .leading) {
                        Text("Clock").font(.headline)
                        Picker("Time", selection: $timeControl) {
                            ForEach(timeControls.indices, id: \.self) { Text(timeControls[$0].label).tag($0) }
                        }.pickerStyle(.menu)
                        Text("Each player has their own clock — you can stall on your time waiting for your partner to send a piece. Run out and your team loses.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal)
                    if human.contains(false) {
                        VStack(alignment: .leading) {
                            Text("Computer strength").font(.headline)
                            Picker("Level", selection: $level) { ForEach(1...10, id: \.self) { Text("Level \($0)").tag($0) } }
                            Text(Difficulty(level: level).blurb).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal)
                    }
                    Button { let tc = timeControls[timeControl]; onStart(buildSeats(), tc.base, tc.inc) } label: {
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
                .background(human == config ? brand.accent.opacity(0.25) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
    private func teamCard(_ title: String, seats: [BughouseSeat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(brand.accent)
            ForEach(seats) { s in
                HStack {
                    Text(s.label); Spacer()
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

/// The live two-board match — bigger landscape boards, focus toggle, per-board themes, public chat.
public struct BughouseGameView: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance
    @StateObject private var game: BughouseController
    let onExit: () -> Void
    @State private var showSave = false
    @State private var saveName = ""
    @State private var focusMine = false
    @State private var showChat = false
    @AppStorage("bug.board1Theme") private var board1Theme = "brown"
    @AppStorage("bug.board2Theme") private var board2Theme = "green"
    private let overhead: CGFloat = 132   // two reserves + two clock rows + turn line

    public init(brand: Brand, appearance: Appearance = .shared,
                controller: BughouseController, onExit: @escaping () -> Void) {
        self.brand = brand; self.appearance = appearance; self.onExit = onExit
        _game = StateObject(wrappedValue: controller)
    }

    public var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let cmdH: CGFloat = game.hasHuman ? 56 : 0
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
        .sheet(isPresented: $showChat) { chatLog }
    }

    private func theme(_ b: Int) -> BoardTheme { BoardTheme.theme(id: b == 0 ? board1Theme : board2Theme) }

    @ViewBuilder
    private func boards(landscape: Bool, width: CGFloat, availH: CGFloat) -> some View {
        if landscape {
            if focusMine && game.hasHuman {
                let my = game.myBoard
                HStack(alignment: .center, spacing: 14) {
                    boardColumn(my, size: min(width * 0.58, availH - overhead))
                    boardColumn(1 - my, size: min(width * 0.34, availH - overhead))
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
                Button { showChat = true } label: { Image(systemName: "bubble.left.and.bubble.right").font(.title3) }
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
            HStack { Text("Board \(b + 1)").font(.caption2.weight(.bold)).foregroundStyle(.secondary); Spacer(); clockLabel(b, .black) }
                .frame(width: size)
            pocket(b, color: .black, size: size, interactive: game.isHumanToMove(b) && bd.pos.sideToMove == .black)
            BoardView(position: bd.pos, lastMove: bd.lastMove, selected: bd.selected, targets: bd.targets,
                      checkSquare: checkSquare(bd.pos), size: size, boardTheme: theme(b), appearance: appearance,
                      onTap: { game.tap(board: b, $0) },
                      onMove: { f, t in game.move(board: b, from: f, to: t) },
                      onDropPiece: { k, sq in game.dropPiece(board: b, k, to: sq) })
            pocket(b, color: .white, size: size, interactive: game.isHumanToMove(b) && bd.pos.sideToMove == .white)
            HStack { turnPill(b); Spacer(); clockLabel(b, .white) }.frame(width: size)
        }.frame(width: size)
    }

    private func clockLabel(_ b: Int, _ color: PieceColor) -> some View {
        let active = !game.status.isOver && game.boards[b].pos.sideToMove == color
        let seat = game.seat(board: b, color: color)
        let low = game.clock[seat.rawValue] <= 15
        return HStack(spacing: 3) {
            Circle().fill(color == .white ? Color.white : Color.black)
                .frame(width: 8, height: 8).overlay(Circle().strokeBorder(.gray, lineWidth: 0.5))
            Text(game.clockText(seat: seat)).font(.callout.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(low && active ? .red : (active ? .white : .primary))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(active ? AnyShapeStyle(low ? AnyShapeStyle(.red) : AnyShapeStyle(brand.accent)) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
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

    // MARK: Public chat / phrases

    private var commandBar: some View {
        VStack(spacing: 2) {
            if let last = game.chat.last {
                Text(last).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(BughouseController.phrases) { p in chip(p) }
                }.padding(.horizontal, 2)
            }
        }.frame(height: 52)
    }

    private func chip(_ p: BughouseController.Phrase) -> some View {
        Button { game.say(p) } label: {
            Text(p.text).font(.caption.weight(.bold).monospaced())
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(brand.accent.opacity(0.15), in: Capsule()).foregroundStyle(brand.accent)
        }.buttonStyle(.plain)
    }

    /// Table-talk sheet: FICS-style shorthand grid + the public message log.
    private var chatLog: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(game.chat.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if game.chat.isEmpty {
                            Text("Table talk is public — everyone at both boards sees it.").foregroundStyle(.secondary)
                        }
                    }.padding()
                }
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                        ForEach(BughouseController.phrases) { p in
                            Button { game.say(p) } label: {
                                VStack(spacing: 1) {
                                    Text(p.text).font(.caption.weight(.bold).monospaced())
                                    Text(p.hint).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(brand.accent)
                            }.buttonStyle(.plain)
                        }
                    }.padding()
                }.frame(maxHeight: 280)
            }
            .navigationTitle("Table Talk")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showChat = false } } }
        }.tint(brand.accent)
    }

    private func checkSquare(_ pos: Position) -> Int? {
        pos.inCheck(pos.sideToMove) ? pos.kingSquare(pos.sideToMove) : nil
    }
}

/// A populated match for App Store screenshots.
enum DemoBughouse {
    @MainActor static func controller() -> BughouseController {
        var seats: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases { seats[s] = .human }
        let g = BughouseController(seats: seats)
        func m(_ b: Int, _ a: String, _ c: String) { g.move(board: b, from: a.sq, to: c.sq) }
        m(0,"e2","e4"); m(0,"d7","d5"); m(0,"e4","d5"); m(0,"g8","f6"); m(0,"b1","c3"); m(0,"b8","c6")
        m(1,"e2","e4"); m(1,"e7","e5"); m(1,"g1","f3"); m(1,"b8","c6"); m(1,"f1","b5")
        g.say(BughouseController.phrases[10])   // "+N" (send me a knight)
        return g
    }
}

private extension String {
    var sq: Int { let c = Array(self); return rankIndex(c[1])! * 8 + fileIndex(c[0])! }
}
