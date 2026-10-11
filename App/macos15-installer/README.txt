Telescope Data Sort — macOS 15 dual-CPU installer
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
4. Any existing “Telescope Data Sort.app” in /Applications is replaced. A copy under the app's
   earlier name, “Smart Telescope Sort.app”, is moved to the Trash. Settings are kept.
5. You are asked where to save the User Manual PDF; choose any folder.
   (The PDF also remains inside the app: Help → Telescope Data Sort User Manual.)
6. Quarantine flags from email download are cleared automatically.

Contents
- Install.command                          Chooses exactly one CPU build
- Telescope-Data-Sort-User-Manual.pdf     Copied to the folder you choose
- Payloads/arm64/                          Apple Silicon build
- Payloads/x86_64/                         Intel build
- README.txt

Supported data (folder layout detected automatically; nothing to pick)
- Vaonis (Vespera / Stellina) — FTP User/ dated sessions
- ZWO Seestar (S30 / S30 Pro / S50) — USB / Wi-Fi / FIT albums
- DWARFLAB (DWARF 3 / II / mini) — USB / FTP sessions
- Celestron Origin Mark II — USB / FTP object+date FITS
- Any other telescope or camera, including classic setups — TIFF/FITS
  (optional JPG) in folders named for the object, e.g. M31/. Frames inside
  Light, Dark, Flat, Bias or Master folders are set aside, not sorted.
  See "Using data from other telescopes" in the user manual.

Destination for all of them: {Target Folder}/Targets {year}/{DSO}/
Telescope names identify folder layouts only. Independent app; not
affiliated with telescope makers.

Notes
- Bundle ID: com.derry.SmartTelescopeSort
- Open-source freeware
- Ad-hoc signed; not notarized. Mac App Store build is separate.
