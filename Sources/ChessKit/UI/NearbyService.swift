import SwiftUI
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// A wire packet exchanged between two nearby devices.
struct NearbyPacket: Codable {
    enum Kind: String, Codable { case start, move, resign, ready, go, ping }
    var kind: Kind
    var move: Move?
    var hostIsWhite: Bool?
}

/// Peer-to-peer transport for a two-device game over MultipeerConnectivity (Wi-Fi / Bluetooth,
/// no internet, no accounts). Both devices must run the same app (same `serviceType`).
@MainActor
public final class NearbyService: NSObject, ObservableObject {
    public enum Status: Equatable { case idle, hosting, browsing, connected, disconnected }

    @Published public var status: Status = .idle
    @Published public var foundPeers: [MCPeerID] = []
    @Published public var peerName: String?
    /// Set by the host on connect; the colour THIS device controls.
    @Published public var localColor: PieceColor = .white
    /// True once both sides have agreed on colours and the game can start.
    @Published public var ready = false

    // Real-time lock-step (My Turn Chess over Nearby): keep both phones on the same screen.
    /// The peer has tapped "Start" (is at the ready gate).
    @Published public var peerReady = false
    /// Both sides are ready — release the countdown together (see `onGo`).
    @Published public var bothGo = false
    /// No packet heard from the peer recently — they're lagging or have dropped. While true the
    /// board should be covered so the two devices don't drift out of sync.
    @Published public var peerLagging = false

    public var onReceiveMove: ((Move) -> Void)?
    public var onPeerLeft: (() -> Void)?
    /// Fired (on both devices) the moment both players are ready — start the shared countdown.
    public var onGo: (() -> Void)?

    private var localReady = false
    private var heartbeat: Task<Void, Never>?
    private var lastHeard = Date()

    private let serviceType: String
    private let myPeerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var isHost = false

    /// `serviceType` must be ≤15 chars of lowercase letters/digits/hyphens.
    public init(serviceType: String, displayName: String) {
        self.serviceType = serviceType
        self.myPeerID = MCPeerID(displayName: String(displayName.prefix(60)))
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    /// Build a valid service type from a variant title, e.g. "Fischer Random" → "kcfischerrandom".
    public static func serviceType(for title: String) -> String {
        let letters = title.lowercased().unicodeScalars.filter { ("a"..."z").contains(Character($0)) }
        return String(("kc" + String(String.UnicodeScalarView(letters))).prefix(15))
    }

    // MARK: Host / join

    public func host() {
        isHost = true
        status = .hosting
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    public func join() {
        isHost = false
        status = .browsing
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    public func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    public func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        heartbeat?.cancel(); heartbeat = nil
        status = .idle
        ready = false
        peerReady = false; bothGo = false; peerLagging = false; localReady = false
        foundPeers = []
    }

    // MARK: Send

    public func send(_ move: Move) { send(NearbyPacket(kind: .move, move: move, hostIsWhite: nil)) }

    private func send(_ packet: NearbyPacket) {
        guard let data = try? JSONEncoder().encode(packet), !session.connectedPeers.isEmpty else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: Lock-step start + heartbeat

    /// This player tapped "Start" at the ready gate. When both sides are ready the host releases
    /// the shared countdown (`onGo`) on both devices.
    public func markReady() {
        localReady = true
        send(NearbyPacket(kind: .ready))
        maybeGo()
    }

    private func maybeGo() {
        guard localReady, peerReady, !bothGo else { return }
        if isHost { send(NearbyPacket(kind: .go)); fireGo() }   // guest fires on receiving .go
    }
    private func fireGo() { guard !bothGo else { return }; bothGo = true; onGo?() }

    /// Send a heartbeat every second and flag the peer as lagging if we haven't heard back in 3s.
    private func startHeartbeat() {
        heartbeat?.cancel()
        lastHeard = Date()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                send(NearbyPacket(kind: .ping))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                peerLagging = Date().timeIntervalSince(lastHeard) > 3.0
            }
        }
    }
    private func noteHeard() { lastHeard = Date(); if peerLagging { peerLagging = false } }

    private func handleConnected(_ peer: MCPeerID) {
        peerName = peer.displayName
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        if isHost {
            // Host decides colours (host plays White) and tells the guest.
            localColor = .white
            send(NearbyPacket(kind: .start, move: nil, hostIsWhite: true))
            status = .connected
            ready = true
            startHeartbeat()
        }
        // Guest waits for the start packet to learn its colour.
    }
}

extension NearbyService: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected: handleConnected(peerID)
            case .notConnected:
                if status == .connected || ready { status = .disconnected; onPeerLeft?() }
            default: break
            }
        }
    }
    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(NearbyPacket.self, from: data) else { return }
        Task { @MainActor in
            noteHeard()
            switch packet.kind {
            case .start:
                // Guest learns its colour (opposite of host).
                localColor = (packet.hostIsWhite ?? true) ? .black : .white
                status = .connected
                ready = true
                startHeartbeat()
            case .move:
                if let m = packet.move { onReceiveMove?(m) }
            case .resign:
                onPeerLeft?()
            case .ready:
                peerReady = true; maybeGo()
            case .go:
                fireGo()                 // guest: both are ready, start the shared countdown
            case .ping:
                break                    // liveness only (handled by noteHeard above)
            }
        }
    }
    nonisolated public func session(_ s: MCSession, didReceive st: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    nonisolated public func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with prog: Progress) {}
    nonisolated public func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {}
}

extension NearbyService: MCNearbyServiceAdvertiserDelegate {
    nonisolated public func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                       withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)   // auto-accept
    }
}

extension NearbyService: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in if !foundPeers.contains(peerID) { foundPeers.append(peerID) } }
    }
    nonisolated public func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in foundPeers.removeAll { $0 == peerID } }
    }
}
#endif
