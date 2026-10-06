Smart Telescope Sort — macOS 15 dual-CPU installer
=================================================

Requirements
- macOS 15 (Sequoia) or newer
- Apple Silicon (arm64) or Intel (x86_64)

Install
1. Unzip this archive.
2. Double-click Install.command
   - If macOS blocks it: Control-click → Open → Open
3. The installer detects Apple Silicon vs Intel (hardware, not Rosetta)
   and installs ONLY that CPU’s build into /Applications.
   The other processor build in the package is not installed.
4. Any existing “Smart Telescope Sort.app” in /Applications is replaced.
5. You are asked where to save the User Manual PDF; choose any folder.
   (The PDF also remains inside the app: Help → Smart Telescope Sort User Manual.)
6. Quarantine flags from email download are cleared automatically.

Contents
- Install.command                          Chooses exactly one CPU build
- Smart-Telescope-Sort-User-Manual.pdf     Copied to the folder you choose
- Payloads/arm64/                          Apple Silicon build
- Payloads/x86_64/                         Intel build
- README.txt

Supported telescope types (pick in the app)
- Vaonis (Vespera / Stellina) — FTP User/ dated sessions
- ZWO Seestar (S30 / S30 Pro / S50) — USB / Wi-Fi / FIT albums
- DWARFLAB (DWARF 3 / II / mini) — USB / FTP sessions
- Celestron Origin Mark II — USB / FTP object+date FITS

Destination for all brands: Captures/Targets {year}/{DSO}/

Notes
- Bundle ID: com.derry.SmartTelescopeSort
- © 2026 BigSkyAstro.com
- Ad-hoc signed; not notarized. Mac App Store build is separate.
