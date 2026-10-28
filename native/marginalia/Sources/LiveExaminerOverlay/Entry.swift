import LiveExaminerOverlayCore

// Thin executable entry point for the SwiftPM dev flow (`swift build -c
// debug`, `./build_app.sh`). All app logic lives in LiveExaminerOverlayCore
// so an Xcode app target can link the same core and provide its own
// equivalent entry point (see App/main.swift in the Xcode project).
@main
struct Entry {
    static func main() {
        LiveExaminerOverlayApp.run()
    }
}
