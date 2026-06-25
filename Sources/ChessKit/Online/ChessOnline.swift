import SwiftUI
import StoreKit

/// Online play backend client: accounts, StoreKit subscriptions, and the game/lobby API.
/// Talks to the PHP server at kinsman.cc. One shared instance per app.
@MainActor
public final class ChessOnline: ObservableObject {
    public static let shared = ChessOnline()

    let base = "https://kinsman.cc/app/chess/api.php"

    @Published public var token: String? { didSet { UserDefaults.standard.set(token, forKey: "cc.online.token") } }
    @Published public var userId: String?
    @Published public var displayName: String?
    @Published public var email: String?
    @Published public var entitled = false            // server says this account may play online
    @Published public var products: [Product] = []    // StoreKit, sorted all-access → per-game
    @Published public var busy = false
    @Published public var lastError: String?

    public var isSignedIn: Bool { token != nil }

    private init() {
        token = UserDefaults.standard.string(forKey: "cc.online.token")
        displayName = UserDefaults.standard.string(forKey: "cc.online.name")
        email = UserDefaults.standard.string(forKey: "cc.online.email")
    }

    // MARK: HTTP

    struct APIError: Error { let message: String; let code: Int }

    private func request(_ action: String, method: String = "GET", body: [String: Any]? = nil, auth: Bool = true) async throws -> [String: Any] {
        guard var comps = URLComponents(string: base) else { throw APIError(message: "bad url", code: 0) }
        comps.queryItems = [URLQueryItem(name: "action", value: action)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code >= 400 { throw APIError(message: (json["error"] as? String) ?? "Error \(code)", code: code) }
        return json
    }

    // MARK: Accounts (email + password; name captured on register)

    public func register(name: String, email: String, password: String) async {
        await run { let r = try await self.request("register", method: "POST",
            body: ["name": name, "email": email, "password": password], auth: false); self.adopt(r) }
    }
    public func login(email: String, password: String) async {
        await run { let r = try await self.request("login", method: "POST",
            body: ["email": email, "password": password], auth: false); self.adopt(r) }
    }
    public func signOut() { token = nil; displayName = nil; email = nil; entitled = false
        UserDefaults.standard.removeObject(forKey: "cc.online.name")
        UserDefaults.standard.removeObject(forKey: "cc.online.email") }

    private func adopt(_ r: [String: Any]) {
        token = r["token"] as? String
        if let u = r["user"] as? [String: Any] {
            userId = u["id"] as? String
            displayName = u["name"] as? String; email = u["email"] as? String
            UserDefaults.standard.set(displayName, forKey: "cc.online.name")
            UserDefaults.standard.set(email, forKey: "cc.online.email")
        }
    }

    public func refreshEntitlement() async {
        guard isSignedIn else { entitled = false; return }
        do { let r = try await request("sub_status"); entitled = (r["active"] as? Bool) ?? false }
        catch { entitled = false }
    }

    // MARK: StoreKit subscriptions

    public func loadProducts(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        do {
            let ps = try await Product.products(for: ids)
            // all-access first (level 1), then per-game; yearly under monthly within each
            products = ps.sorted { a, b in
                let aa = a.id.contains(".all."), ba = b.id.contains(".all.")
                if aa != ba { return aa }
                return a.price < b.price
            }
        } catch { lastError = error.localizedDescription }
    }

    /// Purchase a subscription, then hand the signed transaction to the server to record entitlement.
    public func purchase(_ product: Product) async -> Bool {
        do {
            var options: Set<Product.PurchaseOption> = []
            if let uid = userId, let u = UUID(uuidString: uid) { options.insert(.appAccountToken(u)) }
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                if case .verified(let txn) = verification {
                    await redeem(jws: verification.jwsRepresentation)
                    await txn.finish()
                    await refreshEntitlement()
                    return entitled
                }
                return false
            case .userCancelled, .pending: return false
            @unknown default: return false
            }
        } catch { lastError = error.localizedDescription; return false }
    }

    public func restore() async {
        await run {
            for await result in Transaction.currentEntitlements {
                if case .verified = result { await self.redeem(jws: result.jwsRepresentation) }
            }
            await self.refreshEntitlement()
        }
    }

    /// Send a StoreKit JWS transaction to the server, which verifies it and grants the entitlement.
    private func redeem(jws: String) async {
        guard isSignedIn else { return }
        _ = try? await request("redeem", method: "POST", body: ["jws": jws])
    }

    // MARK: Games / lobby

    public struct OnlineGame { public let id: String; public let code: String; public let seats: Int }

    public func createGame(variant: String, base baseSecs: Int, increment: Int) async -> OnlineGame? {
        do { let r = try await request("game_create", method: "POST",
                body: ["variant": variant, "base": baseSecs, "increment": increment])
            return OnlineGame(id: r["game_id"] as? String ?? "", code: r["invite_code"] as? String ?? "",
                              seats: r["seats_total"] as? Int ?? 2)
        } catch let e as APIError { lastError = e.message; return nil } catch { return nil }
    }
    public func joinGame(code: String) async -> (gameId: String, seat: Int)? {
        do { let r = try await request("game_join", method: "POST", body: ["code": code])
            return (r["game_id"] as? String ?? "", r["seat_index"] as? Int ?? 0)
        } catch let e as APIError { lastError = e.message; return nil } catch { return nil }
    }
    public func postMove(gameId: String, board: Int, ply: Int, payload: String) async {
        _ = try? await request("move_post", method: "POST",
            body: ["game_id": gameId, "board": board, "ply": ply, "payload": payload])
    }
    public func poll(gameId: String, since: Int) async -> (moves: [[String: Any]], status: String)? {
        do { let r = try await request("move_poll&game_id=\(gameId)&since=\(since)")
            let moves = r["moves"] as? [[String: Any]] ?? []
            let status = (r["game"] as? [String: Any])?["status"] as? String ?? "lobby"
            return (moves, status)
        } catch { return nil }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true; lastError = nil
        do { try await work() } catch let e as APIError { lastError = e.message } catch { lastError = error.localizedDescription }
        busy = false
    }
}
