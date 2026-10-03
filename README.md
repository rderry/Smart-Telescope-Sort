<p align="center">
  <a href="https://bigskyastro.com"><img src="docs/bigskyastro-banner.jpg" alt="BigSkyAstro" width="820"></a>
</p>

<img src="App/Icons/AppIcon-source.png" alt="Smart Telescope Sort icon" width="128" align="right">

# Smart Telescope Sort

[![Open Source](https://img.shields.io/badge/open%20source-yes-brightgreen)](LICENSE)
[![License: MIT with attribution](https://img.shields.io/badge/license-MIT%20with%20attribution-blue)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)](#build)
[![BigSkyAstro](https://img.shields.io/badge/by-BigSkyAstro-1f3a68)](https://bigskyastro.com)

Free, open-source macOS app from [BigSkyAstro](https://bigskyastro.com) that moves smart-telescope captures from a download folder into `Targets {year}/{object}`.

## Credit BigSkyAstro

**If you modify and distribute this app, in source or binary form, please give credit to BigSkyAstro: include the BigSkyAstro logo ([`docs/bigskyastro-banner.jpg`](docs/bigskyastro-banner.jpg)) and a link to our web page: [https://bigskyastro.com](https://bigskyastro.com).**

A credit line such as this is enough:

> Based on Smart Telescope Sort by BigSkyAstro — https://bigskyastro.com

The [LICENSE](LICENSE) makes this credit a condition of redistribution.

## What it does

- Detects the capture layout from your Captures folder: dated session folders, object albums, session folders, or object-and-date folders.
- Asks once where your Original Targets, Processing Targets and Backup Storage folders live, with an option to save each as the default.
- Lets you choose which files move: TIFF, JPG/JPEG, FITS/FIT, or all of them.
- Before sorting, can back up the capture folders as a zip or tarball using the archiver built into macOS. There is nothing extra to install.
- Lists every file in a review window, with its object, date and target folder, before anything moves.
- Asks you to name each backup and shows its progress, with a Cancel button.
- Marks files already in Targets as duplicates and asks Yes or No before sending them to the Trash.
- After a sort, asks Yes or No before trashing a finished capture folder that still holds images you didn't choose to move.
- The Source code on GitHub link asks for this credit, showing the logo and the bigskyastro.com link, then opens this repository when you click Continue.

Independent app. Not affiliated with or created by telescope manufacturers. Model names in the source identify folder layouts only. A modified build should keep the product name free of those trademarks.

The Mac App Store edition is signed and distributed separately. A build from this repository is your own local copy.

## Build

Requires Xcode command-line tools.

```bash
cd App
chmod +x build-app.sh
./build-app.sh
```

The app is written next to the `App` folder as `Smart Telescope Sort.app`. The script compiles for the Mac you are on and ad-hoc signs it. You do not need an Apple Developer certificate to run your own changes.

Rebuild the bundled manual with:

```bash
python3 App/Scripts/build-user-manual.py
```

That script needs `reportlab`.

## Try it

`Demo Captures/` holds placeholder files, not real images. In the app, set Source Captures to one brand folder, such as `Demo Captures/Seestar`, then press Review file plan.

| Folder | Layout |
|--------|--------|
| `Vaonis/` | Dated session folders |
| `Seestar/` | Object album folders |
| `DWARF/` | Session folders |
| `Origin/` | Object and date folders |

## License

Open source under the MIT License, with an attribution requirement. See [LICENSE](LICENSE).

Copyright (c) 2026 [BigSkyAstro](https://bigskyastro.com).
