# ChessKit

A reusable Swift package for building **chess apps and variants** on iOS / iPadView /
Mac Catalyst. One protocol (`ChessVariant`) gets you a fully playable game: legal-move
generation, a variant-aware AI opponent, an interactive SwiftUI board (tap **or**
drag-and-drop), board themes, piece sets, and end-of-game detection.

It powers four shipping apps — **Kriegspiel Chess**, **Crazyhouse Chess**,
**Atomic Chess**, and **Fischer Random Chess** — each of which is essentially:

```swift
import SwiftUI
import ChessKit

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ChessGameView(
                variant: CrazyhouseChess(),
                brand: Brand(accent: .orange, title: "Crazyhouse", systemImage: "shippingbox.fill")
            )
        }
    }
}
```

## What's in the box

| Layer | Files | Purpose |
|---|---|---|
| **Core** | `Core/Board.swift`, `Move.swift`, `MoveGen.swift`, `SAN.swift`, `Variant.swift` | `Position`, `Move`, pseudo/legal move generation, generalized (Chess960-aware) castling, SAN, the `ChessVariant` protocol |
| **Variants** | `Variants/*.swift` | `StandardChess`, `KriegspielChess` (+ `KriegspielReferee`), `CrazyhouseChess`, `AtomicChess`, `Chess960` |
| **AI** | `AI/SearchEngine.swift` | Variant-agnostic negamax + alpha-beta with `Difficulty` presets |
| **UI** | `UI/*.swift` | `ChessGameView` (the whole screen), `BoardView`, `GameController`, `PocketView`, `Appearance`, `SettingsView`, `Brand`/`Theme` |
| **Resources** | `Resources/Pieces.xcassets` | Wikipedia / Alpha / USCF piece artwork (bundled via `Bundle.module`) |

## Adding a new variant

Conform to `ChessVariant`. Most of it has sensible defaults — you typically implement
`legalMoves`, `make`, and `status`:

```swift
struct ThreeCheck: ChessVariant {
    var name: String { "Three-check" }
    func legalMoves(_ p: Position) -> [Move] { StandardChess.legalStandardMoves(p) }
    func make(_ m: Move, in p: Position) -> Position { StandardRules.apply(m, to: p).position }
    func status(_ p: Position) -> GameStatus { /* …count checks… */ }
}
```

`SearchEngine` and `ChessGameView` then work with it automatically.

## Tests

`swift test` runs the engine suite: standard + Kiwipete **perft**, fool's mate,
Crazyhouse pockets/drops, Atomic explosions, the Kriegspiel referee, all **960**
Chess960 back ranks, drag-move application, and AI legality across every variant.

## Build

Pure SwiftPM. Apps consume it as a local package (`packages: { ChessKit: { path: ../ChessKit } }`
in their XcodeGen `project.yml`). Requires Swift 5.9+, iOS 17+ / macOS 14+.
