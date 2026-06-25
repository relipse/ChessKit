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
    @Environment(\.dismiss) private var dismiss

    #if canImport(MultipeerConnectivity)
    @StateObject private var service: NearbyService
    @State private var playing = false

    public init(variant: ChessVariant, brand: Brand, appearance: Appearance = .shared, store: GameStore) {
        self.variant = variant; self.brand = brand; self.appearance = appearance; self.store = store
        _service = StateObject(wrappedValue: NearbyService(
            serviceType: NearbyService.serviceType(for: variant.name),
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
            .onChange(of: service.ready) { _, ready in if ready { playing = true } }
            .gameCover(isPresented: $playing) {
                ChessGameView(variant: variant, brand: brand, appearance: appearance,
                              store: store, nearby: service, onExit: { service.stop(); dismiss() })
            }
        }
        .tint(brand.accent)
    }
    #else
    public init(variant: ChessVariant, brand: Brand, appearance: Appearance = .shared, store: GameStore) {
        self.variant = variant; self.brand = brand; self.appearance = appearance; self.store = store
    }
    public var body: some View {
        Text("Nearby play isn't available on this device.").padding()
    }
    #endif
}
