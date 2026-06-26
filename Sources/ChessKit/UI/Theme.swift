import SwiftUI

/// Per-app branding: the accent colour and a one-word board name. Apps pass their own
/// `Brand` so each variant app feels distinct while sharing all the UI code.
public struct Brand: Sendable {
    public var accent: Color
    public var title: String
    public var systemImage: String
    /// Optional app-bundle image asset (the app's logo art) shown on the splash screen.
    /// nil → fall back to `systemImage`.
    public var logoAsset: String?
    /// Numeric App Store ID (e.g. "6743000000"); enables direct Rate/Share links once known.
    public var appStoreID: String?
    /// Game Center leaderboard ID for wins (configured in App Store Connect).
    public var leaderboardID: String?
    /// Online play (Internet Game). `onlineSlug` keys the per-game product IDs; `onlineAllSlug`
    /// keys the all-access product IDs (usually the same; Bughouse's all-access uses "chess").
    public var onlineSlug: String?
    public var onlineAllSlug: String?

    public init(accent: Color, title: String, systemImage: String = "crown.fill",
                leaderboardID: String? = nil, appStoreID: String? = nil,
                onlineSlug: String? = nil, onlineAllSlug: String? = nil,
                logoAsset: String? = nil) {
        self.accent = accent
        self.title = title
        self.systemImage = systemImage
        self.logoAsset = logoAsset
        self.appStoreID = appStoreID
        self.leaderboardID = leaderboardID
        self.onlineSlug = onlineSlug
        self.onlineAllSlug = onlineAllSlug ?? onlineSlug
    }

    /// The four subscription product IDs for this app (all-access mo/yr, this-game mo/yr).
    public var onlineProductIDs: [String] {
        guard let s = onlineSlug else { return [] }
        let a = onlineAllSlug ?? s
        return ["cc.kinsman.\(a).all.monthly", "cc.kinsman.\(a).all.yearly",
                "cc.kinsman.\(s).game.monthly", "cc.kinsman.\(s).game.yearly"]
    }
    public var onlineGameKey: String { onlineSlug ?? "standard" }
    public static let standard = Brand(accent: Color(red: 0.55, green: 0.36, blue: 0.20), title: "Chess")

    /// Title for headings — avoids "Chess Chess" when the variant title already says "Chess".
    public var displayTitle: String {
        title.range(of: "chess", options: .caseInsensitive) != nil ? title : "\(title) Chess"
    }

    /// App Store listing URL (falls back to a search if the id isn't set yet).
    public var appStoreURL: URL {
        if let id = appStoreID { return URL(string: "https://apps.apple.com/app/id\(id)")! }
        return URL(string: "https://apps.apple.com/")!
    }
    /// Deep link that opens the App Store review prompt.
    public var reviewURL: URL {
        if let id = appStoreID {
            return URL(string: "https://apps.apple.com/app/id\(id)?action=write-review")!
        }
        return appStoreURL
    }
    public var shareMessage: String { "Play \(displayTitle) — beat the computer!" }
}

public enum Theme {
    public static let darkBrown = Color(red: 0.247, green: 0.165, blue: 0.094)
    public static let brown     = Color(red: 0.478, green: 0.322, blue: 0.188)
    public static let cream     = Color(red: 0.96,  green: 0.93,  blue: 0.86)

    public static func heroGradient(_ accent: Color) -> LinearGradient {
        LinearGradient(colors: [accent.opacity(0.9), darkBrown],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A small status pill (e.g. "● THINKING", "YOUR MOVE").
public struct PillBadge: View {
    public let text: String
    public var color: Color
    public var filled: Bool
    public var pulsing: Bool
    @State private var pulse = false

    public init(_ text: String, color: Color, filled: Bool = true, pulsing: Bool = false) {
        self.text = text; self.color = color; self.filled = filled; self.pulsing = pulsing
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy)).tracking(0.5)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filled ? color : color.opacity(0.15), in: Capsule())
            .foregroundStyle(filled ? .white : color)
            .opacity(pulsing && pulse ? 0.5 : 1.0)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}
