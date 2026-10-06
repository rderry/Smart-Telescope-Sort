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
                Button("Assumptions and Backup Advice…") {
                    NotificationCenter.default.post(name: .showAssumptions, object: nil)
                }
                Button("Terms Acceptance Record…") {
                    TermsRecordInfo.show()
                }
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
                    SourceCodeCredit.openRepository()
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

/// Where the locked terms-acceptance PDF is, and when the terms were accepted.
enum TermsRecordInfo {
    @MainActor
    static func show() {
        let url = AgreementRecord.fileURL
        let alert = NSAlert()
        if let record = AgreementRecord.read() {
            alert.messageText = "Terms accepted \(record.agreedAt)"
            alert.informativeText = "On this Mac (\(record.macAddress)), terms version \(record.termsVersion).\n\n"
                + "The record is a hidden, read-only, password-locked PDF:\n\(url.path)"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Path")
        } else {
            alert.messageText = "No terms acceptance recorded"
            alert.informativeText = "It is saved when you check “I have read and accept the above” and click I Understand. It will be kept at:\n\(url.path)"
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}

/// Asks for BigSkyAstro credit before opening the open-source repository.
enum SourceCodeCredit {
    @MainActor
    static func openRepository() {
        let alert = NSAlert()
        alert.messageText = "Smart Telescope Sort is open source"
        alert.informativeText = """
            If you change it and give it away, please give credit to BigSkyAstro: \
            include the BigSkyAstro logo and a link to bigskyastro.com.

            Credit line: "Based on Smart Telescope Sort by BigSkyAstro — https://bigskyastro.com"
            """
        alert.accessoryView = accessory()
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(BigSkyAstroWebLinks.sourceCode)
        }
    }

    @MainActor
    private static func accessory() -> NSView {
        let width: CGFloat = 300
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        if let url = Bundle.main.url(forResource: "BigSkyAstro-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let logo = NSImageView(image: image)
            logo.imageScaling = .scaleProportionallyUpOrDown
            logo.wantsLayer = true
            logo.layer?.cornerRadius = 8
            logo.layer?.masksToBounds = true
            logo.translatesAutoresizingMaskIntoConstraints = false
            logo.widthAnchor.constraint(equalToConstant: width).isActive = true
            logo.heightAnchor.constraint(equalToConstant: width * image.size.height / max(image.size.width, 1)).isActive = true
            stack.addArrangedSubview(logo)
        }
        let link = NSButton(title: "https://bigskyastro.com", target: LinkTarget.shared, action: #selector(LinkTarget.openHome))
        link.isBordered = false
        link.contentTintColor = .linkColor
        stack.addArrangedSubview(link)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return stack
    }

    private final class LinkTarget: NSObject {
        static let shared = LinkTarget()
        @objc func openHome() { NSWorkspace.shared.open(BigSkyAstroWebLinks.home) }
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
