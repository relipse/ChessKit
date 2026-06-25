import SwiftUI
#if canImport(GameKit)
import GameKit
#endif

/// Game Center integration: authenticate the local player, submit a score whenever the
/// human wins, and present the leaderboard dashboard. Each win's score rewards higher
/// difficulty and fewer moves (a quick win at Level 10 beats a long grind at Level 1).
@MainActor
public final class GameCenter: ObservableObject {
    public static let shared = GameCenter()
    @Published public private(set) var authenticated = false

    private init() {}

    /// Score formula: difficulty dominates, then fewer moves ranks higher.
    public static func score(difficulty: Difficulty, moves: Int) -> Int {
        difficulty.level * 100_000 + max(0, 10_000 - moves)
    }

    #if canImport(GameKit)
    public func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, _ in
            if let viewController { Self.present(viewController) }
            self?.authenticated = GKLocalPlayer.local.isAuthenticated
        }
    }

    /// Submit a win to the leaderboard (no-op if not authenticated or id is nil).
    public func submitWin(leaderboardID: String?, difficulty: Difficulty, moves: Int) {
        guard let id = leaderboardID, GKLocalPlayer.local.isAuthenticated else { return }
        let value = Self.score(difficulty: difficulty, moves: moves)
        GKLeaderboard.submitScore(value, context: 0, player: GKLocalPlayer.local,
                                  leaderboardIDs: [id]) { _ in }
    }

    public func showDashboard(leaderboardID: String?) {
        #if os(iOS)
        let vc: GKGameCenterViewController
        if let id = leaderboardID {
            vc = GKGameCenterViewController(leaderboardID: id, playerScope: .global, timeScope: .allTime)
        } else {
            vc = GKGameCenterViewController(state: .leaderboards)
        }
        let delegate = DashboardDelegate.shared
        vc.gameCenterDelegate = delegate
        Self.present(vc)
        #endif
    }

    #if os(iOS)
    private static func present(_ vc: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }

    final class DashboardDelegate: NSObject, GKGameCenterControllerDelegate {
        static let shared = DashboardDelegate()
        func gameCenterViewControllerDidFinish(_ vc: GKGameCenterViewController) {
            vc.dismiss(animated: true)
        }
    }
    #else
    private static func present(_ vc: Any) {}
    #endif

    #else
    public func authenticate() {}
    public func submitWin(leaderboardID: String?, difficulty: Difficulty, moves: Int) {}
    public func showDashboard(leaderboardID: String?) {}
    #endif
}

#if os(iOS)
private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } ?? windows.first }
}
#endif
