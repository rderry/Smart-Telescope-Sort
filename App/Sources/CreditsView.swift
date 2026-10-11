import SwiftUI
import AppKit

/// The Credits popup: BigSkyAstro logo, the people, then the data sources. Follows the system appearance and scrolls.
struct CreditsSheet: View {
    var close: () -> Void

    private static let logo: NSImage? = Bundle.main.url(forResource: Credits.logoResource, withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let logo = Self.logo {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("BigSkyAstro")
                    }
                    section(Credits.peopleHeading, lines: Credits.peopleLines)
                    section(Credits.dataSourcesHeading, lines: Credits.dataSources)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section(_ heading: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.headline)
            ForEach(lines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
