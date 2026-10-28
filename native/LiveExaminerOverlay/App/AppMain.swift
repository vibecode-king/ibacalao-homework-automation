import LiveExaminerOverlayCore

// Xcode app target entry point. Mirrors Sources/LiveExaminerOverlay/Entry.swift
// (the SwiftPM dev-flow executable) — both link the same
// LiveExaminerOverlayCore product and boot the identical AppDelegate.
@main
struct AppMain {
    static func main() {
        LiveExaminerOverlayApp.run()
    }
}
