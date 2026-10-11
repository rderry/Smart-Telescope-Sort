import Foundation

/// Prints what the Mac sorter (App/Sources/CaptureSorter.swift) finds and plans for a Capture Folder, in the same
/// line format as `SmartTelescopeSort.Cli report`, so the Windows port can be diffed against it. With --sort it also
/// runs copySort (copy and check only; originals are never deleted). Built by run-golden.sh into /tmp.
@main
struct GoldenReport {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let sort = args.contains("--sort")
        args.removeAll { $0 == "--sort" }
        guard args.count >= 2 else {
            print("usage: GoldenReport <source> <targets> [tiff,fits,jpeg] [--sort]")
            exit(2)
        }
        let source = URL(fileURLWithPath: args[0], isDirectory: true)
        let targets = URL(fileURLWithPath: args[1], isDirectory: true)
        let types = (args.count > 2 ? args[2] : "tiff,fits").split(separator: ",").compactMap { SortFileType(rawValue: String($0)) }
        CaptureSorter.sortExtensions = types.reduce(into: []) { $0.formUnion($1.extensions) }

        var lines: [String] = []
        lines.append("layout \(TelescopeKind.detect(in: source)?.rawValue ?? "none")")
        let entries = try CaptureSorter.scan(kind: .vaonis, sourceRoot: source, targetsRoot: targets).entries
        for e in entries {
            lines.append("entry \(e.captureFolder)|\(e.year)|\(e.month)|\(e.object)|\(e.session)|\(e.imageFolders)|\(e.files)|"
                + "\(e.formats.joined(separator: ","))|\(e.needsObjectName)")
        }
        let (plans, _) = CaptureSorter.preview(entries: entries)
        for p in plans {
            lines.append("plan \(CaptureSorter.relativePath(of: p.source, in: source))|"
                + "\(CaptureSorter.relativePath(of: p.destination, in: targets))|\(p.action == .move ? "move" : "duplicate")")
        }
        let setAside = CaptureSorter.setAsideFolders(under: source, monitor: nil)
        for f in setAside.calibration { lines.append("calibration \(f.path)|\(counts(f.images))") }
        for f in setAside.plateSolves { lines.append("platesolve \(f.path)|\(counts(f.images))") }
        for m in CaptureSorter.plateSolveMoves(setAside.plateSolves, sourceRoot: source) {
            lines.append("psmove \(m.path)|\(m.object ?? "-")|\(m.year)|\(m.session)|\(m.subpath)|\(m.images)")
        }
        if sort {
            let result = CaptureSorter.copySort(entries: entries, sourceRoot: source, targetsRoot: targets)
            for c in result.copied {
                lines.append("copied \(CaptureSorter.relativePath(of: c.original, in: source))|\(CaptureSorter.relativePath(of: c.copy, in: targets))")
            }
            for f in result.failed { lines.append("failed \(f)") }
            if let error = result.error { lines.append("error \(error)") }
        }
        for line in lines.sorted() { print(line) }
    }

    static func counts(_ images: [String: Int]) -> String {
        images.keys.sorted().map { "\($0)=\(images[$0]!)" }.joined(separator: ",")
    }
}
