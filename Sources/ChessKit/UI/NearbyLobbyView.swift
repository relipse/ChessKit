import SwiftUI
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Host or join a nearby two-device game, then drop into the board once connected.
public struct NearbyLobbyView: View {
    let variant: ChessVariant
    let brand: Brand
    @ObservedObject var appearance: Appearance
    let store: GameStore
    /// Called once the two devices are connected — the parent presents the board full-screen
    /// (so it isn't trapped inside this lobby sheet).
    var onConnected: (NearbyService) -> Void
    @Environment(\.dismiss) private var dismiss

    #if canImport(MultipeerConnectivity)
    @StateObject private var service: NearbyService

    public init(variant: ChessVariant, brand: Brand, appearance: Appearance = .shared, store: GameStore,
                onConnected: @escaping (NearbyService) -> Void) {
        self.variant = variant; self.brand = brand; self.appearance = appearance; self.store = store
        self.onConnected = onConnected
        // Service id derives from the brand title so it matches the app's Info.plist
        // NSBonjourServices entry (also generated from the title).
        _service = StateObject(wrappedValue: NearbyService(
            serviceType: NearbyService.serviceType(for: brand.title),
            displayName: NearbyLobbyView.deviceName()))
    }

    static func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "wifi").font(.system(size: 54)).foregroundStyle(brand.accent)
                Text("Play \(brand.displayTitle) with someone nearby")
                    .font(.title3.weight(.bold)).multilineTextAlignment(.center)
                Text("Both devices need this app. Connects over Wi-Fi/Bluetooth — no internet or accounts.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

                switch service.status {
                case .idle:
                    VStack(spacing: 12) {
                        Button { service.host() } label: {
                            Label("Host a Game", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.borderedProminent)
                        Button { service.join() } label: {
                            Label("Join a Game", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.bordered)
                    }.padding(.horizontal, 30)
                case .hosting:
                    VStack(spacing: 8) { ProgressView(); Text("Waiting for a player to join…").font(.callout) }
                case .browsing:
                    VStack(spacing: 8) {
                        Text("Nearby games").font(.headline)
                        if service.foundPeers.isEmpty { ProgressView().padding(.top, 4) }
                        ForEach(service.foundPeers, id: \.self) { peer in
                            Button { service.invite(peer) } label: {
                                Label(peer.displayName, systemImage: "iphone").frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }.padding(.horizontal, 30)
                case .connected:
                    VStack(spacing: 8) { ProgressView(); Text("Connected! Starting…").font(.callout) }
                case .disconnected:
                    Text("Disconnected.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Play Nearby")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { service.stop(); dismiss() } } }
            // Hand the connected transport up so the menu presents the board full-screen,
            // rather than launching it nested inside this (small) lobby sheet.
            .onChange(of: service.ready) { _, ready in if ready { onConnected(service) } }
        }
        .tint(brand.accent)
    }
    #else
    public init(variant: ChessVariant, brand: Brand, appearance: Appearance = .shared, store: GameStore,
                onConnected: @escaping (NearbyService) -> Void) {
        self.variant = variant; self.brand = brand; self.appearance = appearance; self.store = store
        self.onConnected = onConnected
    }
    public var body: some View {
        Text("Nearby play isn't available on this device.").padding()
    }
    #endif
}
