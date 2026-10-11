# Telescope Data Sort

Formerly **Smart Telescope Sort** (renamed in 1.2.1). The GitHub repository, this folder, the bundle ID
`com.derry.SmartTelescopeSort`, the executable name and saved settings keep the earlier name, so upgrades keep each
user's settings.

Separate build from **Vespera Sort program** (Data Files). Lives on Large Drive so the Vaonis-only app stays untouched.

Sorts TIFF, FITS and JPG captures into `Targets {year}/{object}/`: from smart telescopes, and from any other telescope or camera, including classic setups, when the files are arranged as described in [Using data from other telescopes](#using-data-from-other-telescopes).

## Location

`/Volumes/Large Drive/Smart Telescope Sort program/`

## Supported data (layout detected automatically since 1.1)

There is no telescope type to pick. The app detects the folder layout of the Capture Folder each time the preview refreshes and shows it under the window title. The label never changes where files go: every layout is sorted the same way.

| Detected layout | Telescopes | Put files here |
|------|--------|----------------|
| **Dated session folders** | Vespera / Stellina | FTP `User/` dated sessions into Captures |
| **Object album folders** | Seestar S30 / S30 Pro / S50 | USB / Wi‑Fi / FIT export → object albums in Captures |
| **Session folders** | DWARF 3 / II / mini | USB or FTP session folders into Captures |
| **Object and date folders** | Celestron Origin Mark II | Raw FITS folders (object+date) via USB stick or FTP into Captures |
| **Folders from any telescope or camera** | Any other, including classic setups | Folders named for the object (see below) |

Destination for all of them: `{Target Folder}/Targets {year}/{object}/`.

Telescope names identify folder layouts only. Telescope Data Sort is an independent app and is not affiliated with, endorsed by, or created by those manufacturers.

## Using data from other telescopes

Images from any telescope or camera sort, including a classic setup with a dedicated astronomy camera or a DSLR, captured with programs such as ASIAIR, NINA or SharpCap, or exported from a DSLR as TIFF. The app reads only folder names and file dates (never FITS headers or EXIF), so the files must be arranged like this:

1. **File types.** TIFF (`.tif`, `.tiff`) and FITS (`.fit`, `.fits`) are sorted by default; JPG (`.jpg`, `.jpeg`) when checked under Files to Move. Case doesn't matter. Nothing else is sorted: no camera RAW (CR2, CR3, NEF, ARW, DNG), video (SER, AVI), XISF, PNG or `.fts`. Files are copied unchanged; nothing is converted.
2. **Object from a folder name.** The nearest folder at or above the images whose name holds a catalog number (M, NGC, IC, Sh2, B/Barnard, LDN, LBN, vdB, Abell, Arp, Mel, Cr/Collinder, UGC, PGC, C/Caldwell + a number) or Moon, Sun, a planet or "comet" names the object. Its whole name, without dates, becomes the object folder in capitals with dashes for spaces: `NGC 7000` → `NGC-7000`, `M31 Andromeda` → `M31-ANDROMEDA`. Name the folder just the object.
3. **No object folder?** Those images are listed together before sorting so you can name them; the date is offered as the name.
4. **Year from a folder name, else the file date.** The nearest folder at or above the images named `2026-10-07` (optionally `_22-15-03`), `20261007`, `10-7-2026` or `Object_2026-10-07` gives the date; otherwise the newest image's modification date is used.
5. **Light and calibration folders are set aside, not sorted.** Images inside a folder named `Light`, `Lights`, `Dark`, `Darks`, `Dark Flats`, `Flat`, `Flats`, `Bias` or `Biases` (any case, alone or followed by a non-letter, e.g. `Flats1x20`), or any name starting with `Master`, stay out of Targets; after sorting you choose Move, Leave or Delete for them. Capture programs that save lights in a `Light/` folder need those images moved up into the object folder first.
6. **Also skipped:** folders with *astrometry* in the name (plate solves, offered separately), thumbnails, auto-init frames, hidden files and `Targets {year}` folders.

Example:

```text
Captures/
  M31/
    M31_Light_300s_0001.fits
    M31_Light_300s_0002.fits
  2026-10-07/
    NGC 7000/
      frame_0001.fit
  DSLR Export/
    M45/
      IMG_1234.tif
  M33/
    Light/      (set aside: move these up into M33/ to sort them)
    Darks/      (set aside)
→ Targets {year}/M31/, Targets 2026/NGC-7000/, Targets {year}/M45/
```

`App/Tests/run-tests.sh` checks these rules against classic layouts like this one.

## Build

```bash
cd "/Volumes/Large Drive/Smart Telescope Sort program/App"
chmod +x build-app.sh
./build-app.sh
```

Opens as `Telescope Data Sort.app` next to `App/`.

Tests (sorting rules for classic and calibration layouts):

```bash
App/Tests/run-tests.sh
```

## Windows (1.2.1.0)

The Windows 11 version (WPF, .NET 8) is in `Windows/`: `SmartTelescopeSort.Core` (sorting rules shared with the Mac
golden tree), `SmartTelescopeSort.App`, `SmartTelescopeSort.Cli` and `tests/SmartTelescopeSort.Core.Tests`.

```bash
dotnet test Windows/SmartTelescopeSort.sln
```

Microsoft Store packages are built on Windows with `Windows/installer/package-store.ps1`.

## Demo Captures

Placeholder post-transfer trees (not real images):

`/Volumes/Large Drive/Smart Telescope Sort program/Demo Captures/`

| Folder | Detected layout | What’s inside |
|--------|--------------------|---------------|
| `Vaonis/` | Dated session folders | 4 sessions (M31×2, NGC7023, plan Demo_Night) |
| `Seestar/` | Object album folders | 4 dumps (USB, Wi-Fi, M45 album, S50) |
| `DWARF/` | Session folders | 4 sessions (DWARF 3, FTP, II, mini) |
| `Origin/` | Object and date folders | 4 sets (3 object+date + USB dump) |

Choose a brand subfolder (e.g. `…/Demo Captures/Seestar`) as the **Capture Folder** to see that layout detected. Choosing the `Demo Captures` parent also works: every subfolder is scanned in one pass, and the label shows the most common layout.

## Note

User manual (Help → Telescope Data Sort User Manual / ⇧⌘/) covers assumptions, per-brand offload,
using data from other telescopes, `Targets {year}/{DSO}` for all scopes, Demo Captures, and Review file plan. Rebuild PDF with:

`python3 App/Scripts/build-user-manual.py`

Unistellar's own folder layout isn't recognized in this build.
