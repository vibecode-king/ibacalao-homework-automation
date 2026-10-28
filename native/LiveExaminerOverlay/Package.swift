// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveExaminerOverlay",
    platforms: [.macOS(.v14)],
    products: [
        // Reusable core: everything except the @main entry point. An Xcode
        // macOS app target links this as a local Swift package dependency
        // (see LiveExaminerOverlay.xcodeproj) so app-specific concerns like
        // MAS/DirectDMG entitlements, asset catalog compilation, and
        // signing stay in the Xcode project while the app logic stays here.
        .library(
            name: "LiveExaminerOverlayCore",
            targets: ["LiveExaminerOverlayCore"]
        ),
        // Preserves the existing SwiftPM dev flow: `swift build -c debug`
        // still produces .build/debug/LiveExaminerOverlay for build_app.sh.
        .executable(
            name: "LiveExaminerOverlay",
            targets: ["LiveExaminerOverlay"]
        ),
    ],
    targets: [
        .target(
            name: "LiveExaminerOverlayCore",
            path: "Sources/LiveExaminerOverlayCore",
            // No `resources:` entry: nothing in this target reads
            // Bundle.module for Resources/ (see BrandTheme.swift) — it's
            // Bundle.main everywhere. The SwiftPM dev flow's build_app.sh
            // copies files straight out of Sources/LiveExaminerOverlayCore/
            // Resources/ by path, and the Xcode app target owns the same
            // directory's AppIcon.xcassets via its Resources build phase.
            // Declaring a SwiftPM resource bundle here would just produce an
            // unused, duplicated copy of the same assets. Excluded outright
            // so SwiftPM doesn't warn about unhandled files in this directory.
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "LiveExaminerOverlay",
            dependencies: ["LiveExaminerOverlayCore"],
            path: "Sources/LiveExaminerOverlay"
        ),
    ]
)
