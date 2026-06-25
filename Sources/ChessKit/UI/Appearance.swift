import SwiftUI

/// A named board colour scheme.
public struct BoardTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let light: Color
    public let dark: Color
    public var highlight: Color = Color(red: 0.96, green: 0.86, blue: 0.30).opacity(0.55)

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// 12 board colour schemes, à la Lichess / Chess.com.
    public static let all: [BoardTheme] = [
        BoardTheme(id: "brown",    name: "Brown",      light: rgb(237, 217, 181), dark: rgb(181, 136, 99)),
        BoardTheme(id: "green",    name: "Tournament", light: rgb(235, 236, 208), dark: rgb(119, 149, 86)),
        BoardTheme(id: "blue",     name: "Blue",       light: rgb(222, 227, 230), dark: rgb(140, 162, 173)),
        BoardTheme(id: "purple",   name: "Purple",     light: rgb(239, 239, 239), dark: rgb(132, 118, 186)),
        BoardTheme(id: "wood",     name: "Walnut",     light: rgb(216, 174, 125), dark: rgb(137, 86, 49)),
        BoardTheme(id: "ice",      name: "Ice",        light: rgb(236, 244, 248), dark: rgb(140, 178, 199)),
        BoardTheme(id: "coral",    name: "Coral",      light: rgb(247, 223, 211), dark: rgb(213, 130, 109)),
        BoardTheme(id: "slate",    name: "Slate",      light: rgb(206, 211, 219), dark: rgb(94, 104, 122)),
        BoardTheme(id: "mint",     name: "Mint",       light: rgb(229, 244, 235), dark: rgb(108, 173, 142)),
        BoardTheme(id: "sand",     name: "Desert",     light: rgb(241, 226, 196), dark: rgb(196, 161, 105)),
        BoardTheme(id: "midnight", name: "Midnight",   light: rgb(108, 116, 138), dark: rgb(56, 62, 82),
                   highlight: Color(red: 0.45, green: 0.65, blue: 0.95).opacity(0.55)),
        BoardTheme(id: "crimson",  name: "Crimson",    light: rgb(238, 226, 222), dark: rgb(168, 76, 76))
    ]

    public static func theme(id: String) -> BoardTheme { all.first { $0.id == id } ?? all[0] }
}

/// A named piece set. `assetPrefix` is prepended to the piece code (e.g. "wK"); nil → Unicode glyphs.
public struct PieceSet: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let assetPrefix: String?

    public func assetName(color: PieceColor, kind: PieceKind) -> String? {
        guard let prefix = assetPrefix else { return nil }
        let c = color == .white ? "w" : "b"
        let k: String
        switch kind {
        case .king: k = "K"; case .queen: k = "Q"; case .rook: k = "R"
        case .bishop: k = "B"; case .knight: k = "N"; case .pawn: k = "P"
        }
        return prefix + c + k
    }

    public static let all: [PieceSet] = [
        PieceSet(id: "wikipedia", name: "Wikipedia", assetPrefix: ""),
        PieceSet(id: "alpha",     name: "Alpha",     assetPrefix: "alpha_"),
        PieceSet(id: "uscf",      name: "USCF",      assetPrefix: "uscf_")
        // "Classic" Unicode glyphs removed — the bundled artwork sets look far better.
    ]

    public static func set(id: String) -> PieceSet { all.first { $0.id == id } ?? all[0] }
}

/// Persisted board appearance, observed by the board renderer. Shared across all apps;
/// each app may scope it with a different `UserDefaults` suite name via `Appearance(suite:)`.
@MainActor
public final class Appearance: ObservableObject {
    public static let shared = Appearance()

    private let defaults: UserDefaults

    @Published public var boardThemeID: String { didSet { defaults.set(boardThemeID, forKey: "ck.boardTheme") } }
    @Published public var pieceSetID: String { didSet { defaults.set(pieceSetID, forKey: "ck.pieceSet") } }
    @Published public var showCoordinates: Bool { didSet { defaults.set(showCoordinates, forKey: "ck.coords") } }
    @Published public var showLegalDots: Bool { didSet { defaults.set(showLegalDots, forKey: "ck.legalDots") } }

    public init(suite: String? = nil) {
        let d = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = d
        boardThemeID = d.string(forKey: "ck.boardTheme") ?? "brown"
        pieceSetID = d.string(forKey: "ck.pieceSet") ?? "wikipedia"
        showCoordinates = (d.object(forKey: "ck.coords") as? Bool) ?? true
        showLegalDots = (d.object(forKey: "ck.legalDots") as? Bool) ?? true
    }

    public var theme: BoardTheme { BoardTheme.theme(id: boardThemeID) }
    public var pieceSet: PieceSet { PieceSet.set(id: pieceSetID) }
}
