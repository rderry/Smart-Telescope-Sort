import AppKit
import CoreText
import IOKit

/// The user's acceptance of the launch terms: a hidden, read-only PDF locked with `password`, holding the terms shown,
/// this Mac's MAC address and the date and time they were accepted. It lives in Application Support, so its path is
/// fixed: ~/Library/Application Support/SmartTelescopeSort/Terms-Acceptance.pdf, or inside
/// ~/Library/Containers/com.derry.SmartTelescopeSort/Data/ for the sandboxed App Store build.
enum AgreementRecord {
    /// Written into the record so it shows which wording was accepted.
    static let termsVersion = "2026-10-08"
    static let password = "MontanaSky"

    struct Contents {
        var termsVersion: String
        var agreedAt: String
        var macAddress: String
        var appVersion: String
    }

    static var folderURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SmartTelescopeSort", isDirectory: true)
    }

    static var fileURL: URL { folderURL.appendingPathComponent("Terms-Acceptance.pdf", isDirectory: false) }

    /// True once the record exists. It is written once and never replaced.
    static var isAccepted: Bool {
        #if SCREENSHOTS
        if ScreenshotMode.showsNewUserTerms { return false }
        #endif
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// When the record says the terms were accepted, for showing to the user.
    static var acceptedDate: Date? {
        read().flatMap { ISO8601DateFormatter().date(from: $0.agreedAt) }
    }

    /// Unlocks the PDF and reads the record kept in its Keywords.
    static func read() -> Contents? {
        guard let document = CGPDFDocument(fileURL as CFURL),
              !document.isEncrypted || document.isUnlocked || document.unlockWithPassword(password),
              let info = document.info else { return nil }
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Keywords", &string), let string,
              let keywords = CGPDFStringCopyTextString(string) as String? else { return nil }
        var fields: [String: String] = [:]
        for pair in keywords.components(separatedBy: "; ") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        guard let version = fields["termsVersion"], let agreedAt = fields["agreedAt"] else { return nil }
        return Contents(termsVersion: version, agreedAt: agreedAt,
                        macAddress: fields["macAddress"] ?? "unknown", appVersion: fields["appVersion"] ?? "unknown")
    }

    /// Records acceptance of `terms`. Does nothing when a record already exists, so the first acceptance is kept.
    static func record(terms: [String]) throws {
        guard !isAccepted else { return }
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        let contents = Contents(
            termsVersion: termsVersion,
            agreedAt: iso.string(from: now),
            macAddress: macAddress() ?? "unknown",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        )
        let data = try pdf(contents, terms: terms, date: now)

        let fm = FileManager.default
        var url = fileURL
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let legacy = folderURL.appendingPathComponent(".agreement")
        if fm.fileExists(atPath: legacy.path) {
            try? fm.removeItem(at: legacy)
        }
        try data.write(to: url, options: .withoutOverwriting)
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    }

    private struct PDFError: LocalizedError {
        var errorDescription: String? { "The terms acceptance PDF could not be created." }
    }

    private static func pdf(_ contents: Contents, terms: [String], date: Date) throws -> Data {
        let keywords = [
            "termsVersion=\(contents.termsVersion)",
            "agreedAt=\(contents.agreedAt)",
            "macAddress=\(contents.macAddress)",
            "appVersion=\(contents.appVersion)",
        ].joined(separator: "; ")
        let options: [CFString: Any] = [
            kCGPDFContextTitle: "Telescope Data Sort — Terms Acceptance",
            kCGPDFContextAuthor: "Big Sky Astro",
            kCGPDFContextCreator: "Telescope Data Sort \(contents.appVersion)",
            kCGPDFContextSubject: "Terms accepted \(contents.agreedAt)",
            kCGPDFContextKeywords: keywords,
            kCGPDFContextUserPassword: password,
            kCGPDFContextOwnerPassword: password,
            kCGPDFContextAllowsCopying: false,
            kCGPDFContextAllowsPrinting: true,
            kCGPDFContextEncryptionKeyLength: 128,
        ]
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, options as CFDictionary) else { throw PDFError() }

        let shown = DateFormatter()
        shown.dateStyle = .full
        shown.timeStyle = .long
        let text = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, after: CGFloat = 6) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            text.append(NSAttributedString(string: string + "\n", attributes: [.font: font, .paragraphStyle: style]))
        }
        add("Telescope Data Sort — Terms Acceptance", .boldSystemFont(ofSize: 18), after: 14)
        add("Accepted: \(shown.string(from: date))  (\(contents.agreedAt))", .systemFont(ofSize: 12))
        add("Mac address: \(contents.macAddress)", .systemFont(ofSize: 12))
        add("App version: \(contents.appVersion)    Terms version: \(contents.termsVersion)", .systemFont(ofSize: 12), after: 14)
        add("Terms shown and accepted:", .boldSystemFont(ofSize: 13), after: 8)
        for term in terms {
            add("•  " + term, .systemFont(ofSize: 11), after: 5)
        }
        add("", .systemFont(ofSize: 6))
        add("☑  I have read and accept the above", .boldSystemFont(ofSize: 12))

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: page.insetBy(dx: 54, dy: 54), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame).length
            guard visible > 0 else { break }
            start += visible
        } while start < text.length
        context.closePDF()
        return data as Data
    }

    /// The hardware MAC address of the primary network interface, e.g. "a4:83:e7:12:34:56".
    static func macAddress() -> String? {
        guard let matching = IOServiceMatching("IOEthernetInterface") as NSMutableDictionary? else { return nil }
        matching["IOPropertyMatch"] = ["IOPrimaryInterface": true]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            var parent: io_object_t = 0
            let found = IORegistryEntryGetParentEntry(service, "IOService", &parent) == KERN_SUCCESS
                ? IORegistryEntryCreateCFProperty(parent, "IOMACAddress" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data
                : nil
            if parent != 0 { IOObjectRelease(parent) }
            IOObjectRelease(service)
            if let found {
                return found.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
        }
        return nil
    }
}
