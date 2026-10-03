import SwiftUI
import AppKit

@main
struct SmartTelescopeSortApp: App {
    private var windowTitle: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Smart Telescope Sort"
    }

    var body: some Scene {
        WindowGroup(windowTitle) {
            ContentView()
                .frame(minWidth: 1000, minHeight: 860)
        }
        .defaultSize(width: 1240, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Smart Telescope Sort User Manual") {
                    openBundledManual()
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
                Divider()
                Button("Privacy Policy") {
                    NSWorkspace.shared.open(BigSkyAstroWebLinks.privacyPolicy)
                }
                Button("Smart Telescope Sort on the Web") {
                    NSWorkspace.shared.open(BigSkyAstroWebLinks.appPage)
                }
                Button("Astronomy Observation Planner") {
                    NSWorkspace.shared.open(BigSkyAstroWebLinks.observationPlanner)
                }
                Button("Smart Telescope Planner") {
                    NSWorkspace.shared.open(BigSkyAstroWebLinks.telescopePlanner)
                }
                Button("Source Code on GitHub (Open Source)") {
                    NSWorkspace.shared.open(BigSkyAstroWebLinks.sourceCode)
                }
                Menu("Free Zip & Tarball Apps") {
                    ForEach(ArchiverLinks.all, id: \.title) { link in
                        Button(link.title) { NSWorkspace.shared.open(link.url) }
                    }
                }
                Button("Contact Support") {
                    NSWorkspace.shared.open(BigSkyAstroWebLinks.supportEmail)
                }
                Button("Support (online)") {
                    NSWorkspace.shared.open(BigSkyAstroWebLinks.support)
                }
            }
        }
    }

    private func openBundledManual() {
        if let url = Bundle.main.url(forResource: "Smart-Telescope-Sort-User-Manual", withExtension: "pdf") {
            NSWorkspace.shared.open(url)
            return
        }
        let fallback = URL(fileURLWithPath: "/Volumes/Large Drive/Smart Telescope Sort program/App/Resources/Smart-Telescope-Sort-User-Manual.pdf")
        if FileManager.default.fileExists(atPath: fallback.path) {
            NSWorkspace.shared.open(fallback)
        }
    }
}

enum BigSkyAstroWebLinks {
    static let privacyPolicy = URL(string: "https://bigskyastro.com/privacy")!
    static let appPage = URL(string: "https://bigskyastro.com/macos/smart-telescope-sort")!
    static let support = URL(string: "https://bigskyastro.com/feedback/smart-telescope-sort")!
    static let supportEmail = URL(string: "mailto:support@bigskyastro.com")!
    static let observationPlanner = URL(string: "https://apps.apple.com/app/id6764166535")!
    static let telescopePlanner = URL(string: "https://apps.apple.com/app/id6768153445")!
    static let sourceCode = URL(string: "https://github.com/rderry/Smart-Telescope-Sort")!
    static let home = URL(string: "https://bigskyastro.com")!
}
