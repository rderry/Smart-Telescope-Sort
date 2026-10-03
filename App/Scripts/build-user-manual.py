#!/usr/bin/env python3
"""Build the Smart Telescope Sort user manual PDF (bundled with the app)."""

from __future__ import annotations

import subprocess
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    ListFlowable,
    ListItem,
    PageBreak,
    Paragraph,
    Image,
    KeepTogether,
    Preformatted,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Resources" / "Smart-Telescope-Sort-User-Manual.pdf"
LOGO = ROOT / "Resources" / "BigSkyAstro-logo.png"
SHOTS = ROOT.parent / "AppStore" / "Images" / "1.1"

NAVY = colors.Color(0.05, 0.09, 0.18)
INK = colors.Color(0.12, 0.16, 0.24)
MUTED = colors.Color(0.35, 0.40, 0.48)
ACCENT = colors.Color(0.20, 0.38, 0.72)
CODE_BG = colors.Color(0.94, 0.96, 0.99)


def styles():
    base = getSampleStyleSheet()
    return {
        "cover_title": ParagraphStyle(
            "cover_title", parent=base["Title"], fontName="Helvetica-Bold",
            fontSize=24, leading=28, textColor=NAVY, alignment=TA_CENTER, spaceAfter=10,
        ),
        "cover_sub": ParagraphStyle(
            "cover_sub", parent=base["Normal"], fontName="Helvetica",
            fontSize=12, leading=16, textColor=MUTED, alignment=TA_CENTER, spaceAfter=8,
        ),
        "purpose": ParagraphStyle(
            "purpose", parent=base["Normal"], fontName="Helvetica-Oblique",
            fontSize=11, leading=16, textColor=INK, alignment=TA_CENTER,
            spaceBefore=14, spaceAfter=18,
        ),
        "h1": ParagraphStyle(
            "h1", parent=base["Heading1"], fontName="Helvetica-Bold",
            fontSize=15, leading=19, textColor=NAVY, spaceBefore=14, spaceAfter=8,
        ),
        "h2": ParagraphStyle(
            "h2", parent=base["Heading2"], fontName="Helvetica-Bold",
            fontSize=12, leading=15, textColor=ACCENT, spaceBefore=11, spaceAfter=6,
        ),
        "body": ParagraphStyle(
            "body", parent=base["Normal"], fontName="Helvetica",
            fontSize=10, leading=14, textColor=INK, alignment=TA_JUSTIFY, spaceAfter=8,
        ),
        "bullet": ParagraphStyle(
            "bullet", parent=base["Normal"], fontName="Helvetica",
            fontSize=10, leading=13, textColor=INK, leftIndent=4,
        ),
        "code": ParagraphStyle(
            "code", parent=base["Code"], fontName="Courier",
            fontSize=8.2, leading=11, textColor=INK, backColor=CODE_BG,
            leftIndent=6, rightIndent=6, spaceBefore=4, spaceAfter=10,
        ),
        "caption": ParagraphStyle(
            "caption", parent=base["Normal"], fontName="Helvetica-Oblique",
            fontSize=8.5, leading=11, textColor=MUTED, spaceAfter=10,
        ),
        "footer": ParagraphStyle(
            "footer", parent=base["Normal"], fontName="Helvetica",
            fontSize=8, textColor=MUTED, alignment=TA_CENTER,
        ),
    }


def bullets(items, style):
    return ListFlowable(
        [ListItem(Paragraph(i, style), leftIndent=12, bulletColor=ACCENT) for i in items],
        bulletType="bullet", start="•", leftIndent=18, spaceBefore=2, spaceAfter=8,
    )


def code_block(text, style):
    return Preformatted(text.rstrip() + "\n", style, maxLineLength=96)


def build():
    s = styles()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc = SimpleDocTemplate(
        str(OUT), pagesize=letter,
        leftMargin=0.75 * inch, rightMargin=0.75 * inch,
        topMargin=0.7 * inch, bottomMargin=0.7 * inch,
        title="Smart Telescope Sort User Manual",
        author="BigSkyAstro.com",
    )

    def add_page_number(canvas, _doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(MUTED)
        canvas.drawCentredString(
            letter[0] / 2, 0.4 * inch,
            f"Smart Telescope Sort  ·  © 2026 BigSkyAstro.com  ·  {canvas.getPageNumber()}",
        )
        # Footer link
        canvas.setFillColor(colors.blue)
        canvas.linkURL("https://BigSkyAstro.com", (letter[0] / 2 - 80, 0.32 * inch, letter[0] / 2 + 80, 0.52 * inch))
        canvas.restoreState()

    story = []

    def figure(name, caption, width=6.6 * inch):
        src = SHOTS / f"{name}.png"
        if not src.exists():
            return
        small = Path("/tmp") / f"sts-manual-{name}.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1600",
                        str(src), "--out", str(small)], check=True, capture_output=True)
        img = Image(str(small))
        img.drawHeight = width * img.imageHeight / img.imageWidth
        img.drawWidth = width
        story.append(img)
        story.append(Paragraph(caption, s["caption"]))

    # Cover
    story.append(Spacer(1, 0.6 * inch))
    if LOGO.exists():
        logo = Image(str(LOGO))
        logo.drawHeight = 2.6 * inch * logo.imageHeight / logo.imageWidth
        logo.drawWidth = 2.6 * inch
        story.append(logo)
        story.append(Spacer(1, 16))
    story.append(Paragraph("Smart Telescope Sort", s["cover_title"]))
    story.append(Paragraph("User Manual · Version 1.1", s["cover_sub"]))
    story.append(Paragraph("macOS · Free and open source", s["cover_sub"]))
    story.append(
        Paragraph(
            '© 2026 <link href="https://BigSkyAstro.com" color="blue"><u>BigSkyAstro.com</u></link>',
            s["cover_sub"],
        )
    )
    story.append(
        Paragraph(
            "Organize TIFF, FITS and JPG captures from several smart-telescope brands into one "
            "year / object library. The app does not connect to the telescope: you copy "
            "sessions onto your Mac first, choose that Captures folder, and the app recognizes "
            "the folder layout for you.",
            s["purpose"],
        )
    )
    figure("01-layout-detected", "The main window: the folder layout is detected, and every capture folder is "
           "listed with its object, file count and destination before anything moves.")
    story.append(PageBreak())

    # 1 Assumptions
    story.append(Paragraph("1. Assumptions (read this first)", s["h1"]))
    story.append(bullets([
        "<b>You already moved files off the scope</b> (USB, FTP, or Wi-Fi). The app never talks "
        "to Vaonis, Seestar, DWARF, or Origin hardware.",
        "<b>One brand per Captures folder.</b> The layout is detected from the folder you choose. "
        "Do not mix Seestar albums and Vaonis dated sessions in the same Captures folder.",
        "<b>You choose the file types:</b> TIFF, JPG / JPEG, FITS / FIT, or All. TIFF and FITS "
        "are ticked by default; JPG is usually for viewing and sharing.",
        "<b>Apple Photos is not a source.</b> Export to a Captures folder if images "
        "only live in Photos.",
        "<b>Every brand uses the same library layout:</b> "
        "<font face='Courier'>Targets {year}/{object}/</font> inside your Original Targets folder.",
        "<b>Year</b> comes from dated folder names when present; otherwise from the newest "
        "image file’s modification date.",
        "<b>Object name</b> is decoded from observation / album / object folder names.",
        "<b>Replace only when newer.</b> If Targets already has the same file name, the newer "
        "copy wins. Identical or older copies are marked Duplicate and you are asked about them.",
        "<b>Targets {year}</b> folders are never scanned as sources and are never removed.",
    ], s["bullet"]))

    story.append(Paragraph("1.1 What the app does not do", s["h2"]))
    story.append(bullets([
        "It does not stack, stretch, or post-process images.",
        "It does not support Unistellar in this version.",
        "It does not invent missing object names — if a folder has no usable name, "
        "the object label may be the parent folder name.",
    ], s["bullet"]))

    # 2 Folders
    story.append(Paragraph("2. Your four folders", s["h1"]))
    story.append(
        Paragraph(
            "The first time the app opens it asks where three library folders live. Tick "
            "<b>Save this as default</b> to keep the choice; leave it unticked to use it for "
            "this session only. Each folder has a <b>Change…</b> button in the main window.",
            s["body"],
        )
    )
    story.append(bullets([
        "<b>Source Captures</b> — where you copied the telescope’s sessions. Choose it with the "
        "<b>…</b> button. The folder layout is detected each time the preview refreshes.",
        "<b>Original Targets</b> — holds your <font face='Courier'>Targets {year}</font> folders "
        "of sorted originals. If it is not set, Targets folders stay inside Source Captures.",
        "<b>Processing Targets</b> — where you process objects, one folder per object (for example "
        "<font face='Courier'>Vespera Processing</font>). The file plan shows a green check when "
        "an object already has a processing folder.",
        "<b>Backup Storage</b> — where backups are written before a sort.",
    ], s["bullet"]))
    story.append(code_block(
        "{Original Targets}/Targets {year}/{object}/\n"
        "example:  …/Targets/Targets 2026/M31/\n"
        "example:  …/Targets/Targets 2026/M42/",
        s["code"],
    ))
    story.append(
        Paragraph(
            "If the year folder does not exist yet, the app offers to create "
            "<font face='Courier'>Targets {year}</font> first. No files move when it is created.",
            s["body"],
        )
    )

    # 3 Layouts
    layouts = [Paragraph("3. Detected folder layouts", s["h1"])]
    layouts.append(
        Paragraph(
            "Telescope names identify folder layouts only. Smart Telescope Sort is an independent "
            "app and is not affiliated with, endorsed by, or created by those manufacturers. "
            "The detected layout is shown under the title, for example "
            "<i>Dated session folders · detected</i>.",
            s["body"],
        )
    )
    t = Table([
        ["Layout", "Telescopes", "What the folders look like"],
        ["Dated session folders", "Vespera, Stellina", "2026-09-10_22-15-03_observation_M31"],
        ["Object album folders", "S30, S30 Pro, S50", "M31/, NGC253/ (or a USB dump of albums)"],
        ["Session folders", "DWARF 3, II, mini", "20260907_DWARF3_session/M33/"],
        ["Object-and-date folders", "Origin Mark II", "M31_2026-09-05/"],
    ], colWidths=[1.7 * inch, 1.5 * inch, 3.6 * inch])
    t.setStyle(TableStyle([
        ("FONT", (0, 0), (-1, 0), "Helvetica-Bold", 9),
        ("FONT", (0, 1), (-1, -1), "Helvetica", 9),
        ("FONT", (2, 1), (2, -1), "Courier", 8),
        ("TEXTCOLOR", (0, 0), (-1, 0), NAVY),
        ("BACKGROUND", (0, 0), (-1, 0), CODE_BG),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, colors.Color(0.85, 0.88, 0.93)),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    layouts.append(t)
    story.append(KeepTogether(layouts))
    story.append(Spacer(1, 8))

    # 4 Per brand
    story.append(Paragraph("4. How each telescope gets files onto the Mac", s["h1"]))
    story.append(
        Paragraph(
            "Offload is done outside this app. Below: how vendors typically expose files and "
            "what the app expects after you copy them into Captures.",
            s["body"],
        )
    )

    story.append(Paragraph("4.1 Vespera / Stellina", s["h2"]))
    story.append(bullets([
        "<b>Off the scope:</b> FTP the <b>User/</b> dated folders. Newer models also support "
        "USB-C transfer. Multi-night: stop each night so the project saves, then copy each "
        "night’s dated folder.",
        "<b>In Captures:</b> keep dated names unchanged, e.g. "
        "<font face='Courier'>2026-09-21_11-43-55_observation_M31</font> or "
        "<font face='Courier'>…_plan_My_plan</font> with nested "
        "<font face='Courier'>01-observation-…</font> and <font face='Courier'>01-images-…</font>.",
    ], s["bullet"]))
    story.append(code_block(
        "User/   (on telescope)\n"
        "  2026-09-10_22-15-03_observation_M31/\n"
        "    01-images-initial/\n"
        "      img-0001.tiff\n"
        "      img-0002.fits\n"
        "→ copy whole folder into Captures → Sort → Targets 2026/M31/",
        s["code"],
    ))

    story.append(Paragraph("4.2 S30 / S30 Pro / S50", s["h2"]))
    story.append(bullets([
        "<b>Off the scope:</b> USB cable (drive often shows <b>MyWorks</b> / object "
        "folders), Wi-Fi file share, or app export of <b>FIT</b>.",
        "<b>In Captures:</b> object albums with <font face='Courier'>.fit / .fits</font> "
        "inside (e.g. <font face='Courier'>M31/</font>, or a USB dump containing several albums).",
    ], s["bullet"]))
    story.append(code_block(
        "MyWorks/\n"
        "  M31/\n"
        "    ….fit\n"
        "  NGC253/\n"
        "    ….fits\n"
        "→ copy albums (or the dump) into Captures → Sort → Targets {year}/M31/",
        s["code"],
    ))

    story.append(Paragraph("4.3 DWARF 3 / II / mini", s["h2"]))
    story.append(bullets([
        "<b>Off the scope:</b> USB mass storage (appears as a disk) and/or FTP "
        "(often <font face='Courier'>ftp://192.168.88.1</font> on the telescope’s Wi-Fi).",
        "<b>In Captures:</b> keep each session folder intact. The object may be a nested "
        "folder (e.g. <font face='Courier'>…/M33/</font>) under a dated session.",
    ], s["bullet"]))
    story.append(code_block(
        "Astronomy/<session>/\n"
        "  M33/\n"
        "    stacked.fits\n"
        "    stacked.tiff\n"
        "    sub_0001.fits\n"
        "→ copy session into Captures → Sort → Targets {year}/M33/",
        s["code"],
    ))

    story.append(Paragraph("4.4 Origin Mark II", s["h2"]))
    story.append(bullets([
        "<b>Off the scope:</b> enable <b>Save Raw Images</b>, then copy via USB stick "
        "(FAT32/exFAT) from the app File Manager, or FTP to a computer.",
        "<b>In Captures:</b> folders named object + date, e.g. "
        "<font face='Courier'>M31_2026-09-05/</font> with <font face='Courier'>.fits</font>. "
        "A parent USB dump with several object + date folders also works.",
    ], s["bullet"]))
    story.append(code_block(
        "M31_2026-09-05/\n"
        "  raw_0001.fits\n"
        "  raw_0002.fits\n"
        "→ copy into Captures → Sort → Targets 2026/M31/",
        s["code"],
    ))

    # 5 Workflow
    story.append(Paragraph("5. Step by step", s["h1"]))
    story.append(bullets([
        "Copy sessions off the telescope into a Captures folder.",
        "Open <b>Smart Telescope Sort</b> and answer the folder questions (first launch only).",
        "Set <b>Source Captures</b> (…) to that folder. The layout is detected.",
        "Pick a <b>Year</b> and <b>Month</b> (or All), and tick the <b>Files to Move</b>: "
        "TIFF, JPG / JPEG, FITS / FIT, or All.",
        "Choose a <b>Backup</b>: Off, Zip (.zip), or Tarball (.tar.gz).",
        "Press <b>Review file plan</b> to inspect every file, its target folder and status.",
        "Press <b>Sort eligible files</b>. Name the backup, watch it run, then confirm "
        "<b>Sort now</b>.",
        "Answer the Yes / No questions about duplicates and finished folders.",
        "Browse <font face='Courier'>Targets {year}/{object}</font> for stacking and archive.",
    ], s["bullet"]))
    figure("02-review-file-plan", "Review file plan lists every file grouped by capture folder, with its target "
           "folder, processing folder and status. Nothing has moved yet.")

    # 6 Backups
    story.append(Paragraph("6. Backups", s["h1"]))
    story.append(bullets([
        "<b>Zip or Tarball</b> — chosen in the <b>Backup</b> menu. Before it starts you are asked "
        "to name it; the suggestion is the objects plus the date and time, e.g. "
        "<font face='Courier'>M31 M27 Backup 2026-10-03 15-27.tar.gz</font>. A number is added "
        "if the name is already used.",
        "A progress window shows the size and file count done, time elapsed and time left. "
        "<b>Cancel Backup</b> stops it and removes the partial archive; nothing is moved.",
        "When the backup finishes you are asked to confirm the sort. If it fails, nothing is moved.",
        "<b>Backup Off</b> — the app still offers <b>Back up first…</b>, which copies the capture "
        "folders into a named folder in Backup Storage, or <b>Sort without backup</b>.",
        "Archives are written fast (light compression) using the archiver built into macOS. "
        "If it is missing or a backup fails, <b>Help → Free Zip &amp; Tarball Apps</b> lists "
        "free alternatives.",
    ], s["bullet"]))
    figure("04-backup-progress", "A named Tarball backup running, with Cancel Backup.", width=5.6 * inch)

    # 7 Clean-up prompts
    story.append(Paragraph("7. Duplicates and finished folders", s["h1"]))
    story.append(bullets([
        "<b>Duplicates</b> — files already in Targets (identical or older) are marked "
        "<i>Duplicate</i>. After the sort you are asked <b>Delete duplicates?</b> Yes moves them "
        "to the Trash; the Targets copies are not touched. No leaves them in Captures.",
        "<b>Emptied capture folders</b> are removed after a successful sort.",
        "<b>Finished folders</b> — when a capture folder is sorted but still holds images of a "
        "type you did not tick (for example JPG), you are asked <b>Delete finished folder?</b> "
        "<b>Yes</b> moves the folder and everything left in it to the Trash, "
        "<b>Sort JPG / JPEG First</b> ticks that type and sorts it, and <b>No</b> leaves the "
        "folder in Captures.",
        "Removed folders go to the Trash where the drive supports it.",
    ], s["bullet"]))
    figure("05-finished-folder", "Delete finished folder? — Yes, sort the remaining type first, or No.",
           width=5.6 * inch)

    # 8 Safety
    story.append(Paragraph("8. Safety rules", s["h1"]))
    story.append(bullets([
        "Nothing moves until you confirm the sort.",
        "A destination file is replaced only when the source is newer.",
        "<font face='Courier'>Targets {year}</font> is never scanned as a capture source.",
        "The Captures folder and Targets year folders are never removed during clean-up.",
        "Backups copy whole capture folders; they never modify Targets.",
        "Every deletion asks Yes / No first.",
    ], s["bullet"]))

    # 9 Open source
    story.append(Paragraph("9. Free and open source", s["h1"]))
    story.append(
        Paragraph(
            "Smart Telescope Sort is free, and its source code is on GitHub: "
            '<link href="https://github.com/rderry/Smart-Telescope-Sort" color="blue">'
            "<u>github.com/rderry/Smart-Telescope-Sort</u></link>. Open it from <b>Source code on "
            "GitHub</b> in the sidebar or <b>Help → Source Code on GitHub</b>. The app first asks "
            "for credit, then opens the repository when you click <b>Continue</b>.",
            s["body"],
        )
    )
    story.append(
        Paragraph(
            "If you change it and give it away, please give credit to BigSkyAstro: include the "
            "BigSkyAstro logo and a link to "
            '<link href="https://bigskyastro.com" color="blue"><u>bigskyastro.com</u></link>. '
            "Credit line: <i>“Based on Smart Telescope Sort by BigSkyAstro — https://bigskyastro.com”</i>.",
            s["body"],
        )
    )

    story.append(Paragraph("10. Help and support", s["h1"]))
    story.append(bullets([
        "Privacy policy: https://bigskyastro.com/privacy",
        "App page: https://bigskyastro.com/macos/smart-telescope-sort",
        "Support: https://bigskyastro.com/feedback/smart-telescope-sort · support@bigskyastro.com",
    ], s["bullet"]))

    story.append(Spacer(1, 14))
    story.append(
        Paragraph(
            "End of manual — Help → Smart Telescope Sort User Manual (Shift-Command-/) opens this PDF.",
            s["caption"],
        )
    )

    doc.build(story, onFirstPage=add_page_number, onLaterPages=add_page_number)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    build()
