import Foundation

/// What the Credits popup lists, in order. Same wording and order as the other BigSkyAstro apps
/// (Marketing Field Data/Shared/Credits-Popup-Spec.md). Names only: the popup has no links.
enum Credits {
    struct Person: Equatable {
        var name: String
        var role: String
    }

    /// Bundled banner shown at the top of the popup.
    static let logoResource = "BigSkyAstro-logo"

    static let peopleHeading = "People"
    static let dataSourcesHeading = "Data sources"

    static var peopleLines: [String] { people.map { "\($0.name) — \($0.role)" } }

    static let people = [
        Person(name: "R Derry", role: "Developer and Owner"),
        Person(name: "F Derry", role: "Full Time Beta Tester"),
        Person(name: "Otto", role: "Programming and Smoke Testing"),
        Person(name: "A Derry", role: "Interface Consultant"),
    ]

    /// The app downloads and reads no data. Its only sources are the open-source code and the catalogs whose
    /// designations it recognizes in folder names (CaptureSorter.catalogObject).
    static let dataSources = [
        "GitHub (open source, MIT license)",
        "Messier catalog",
        "New General Catalogue (NGC)",
        "Index Catalogue (IC)",
        "Sharpless catalog (Sh2)",
        "Barnard catalog",
        "Lynds Dark Nebulae (LDN)",
        "Lynds Bright Nebulae (LBN)",
        "van den Bergh catalog (vdB)",
        "Abell catalog",
        "Arp Atlas of Peculiar Galaxies",
        "Melotte catalog",
        "Collinder catalog",
        "Uppsala General Catalogue (UGC)",
        "Principal Galaxies Catalogue (PGC)",
        "Caldwell catalog",
    ]
}
