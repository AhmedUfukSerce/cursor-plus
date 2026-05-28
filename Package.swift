// swift-tools-version:5.9
//
// Cursor+ — a personal macOS menu-bar utility that keeps the Mac "active" by
// moving the real cursor in randomized, human-like, variable-speed paths (with
// occasional scrolling), until stopped with a triple-ESC kill switch.
//
// Built as a SwiftPM executable, then assembled into a signed Cursor+.app by
// scripts/build_app.sh.  Swift 5 language mode (tools-version 5.9) is used
// deliberately to avoid Swift 6 strict-concurrency friction in this small,
// timer-and-callback-heavy agent.

import PackageDescription

let package = Package(
    name: "CursorPlus",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CursorPlus",
            path: "Sources/CursorPlus"
        )
    ]
)
