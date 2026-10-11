#!/usr/bin/env python3
"""Build the Windows user manual PDF from WindowsManualContent.json (the same text the in-app manual shows).

Usage: python3 scripts/build-user-manual.py
Figures come from src/SmartTelescopeSort.App/Assets/Manual/{name}.png and are left out until those screenshots exist.
"""

from __future__ import annotations

import html
import json
import re
import tempfile
from pathlib import Path

from PIL import Image as PILImage
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    Image,
    KeepTogether,
    ListFlowable,
    ListItem,
    PageBreak,
    Paragraph,
    Preformatted,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "src" / "SmartTelescopeSort.Core" / "Resources" / "WindowsManualContent.json"
ASSETS = ROOT / "src" / "SmartTelescopeSort.App" / "Assets"
OUT = ASSETS / "Telescope-Data-Sort-User-Manual.pdf"
LOGO = ASSETS / "BigSkyAstro-logo.png"
SHOTS = ASSETS / "Manual"

NAVY = colors.Color(0.05, 0.09, 0.18)
INK = colors.Color(0.12, 0.16, 0.24)
MUTED = colors.Color(0.35, 0.40, 0.48)
ACCENT = colors.Color(0.20, 0.38, 0.72)
CODE_BG = colors.Color(0.94, 0.96, 0.99)

MARKS = re.compile(r"\*\*(.+?)\*\*|`(.+?)`|\*(.+?)\*")
URL = re.compile(r"(https?://[^\s<)]+|[\w.+-]+@[\w-]+\.[\w.]+)")


def styles():
    base = getSampleStyleSheet()
    return {
        "cover_title": ParagraphStyle("cover_title", parent=base["Title"], fontName="Helvetica-Bold",
                                      fontSize=24, leading=28, textColor=NAVY, alignment=TA_CENTER, spaceAfter=10),
        "cover_sub": ParagraphStyle("cover_sub", parent=base["Normal"], fontName="Helvetica",
                                    fontSize=12, leading=16, textColor=MUTED, alignment=TA_CENTER, spaceAfter=8),
        "notice": ParagraphStyle("notice", parent=base["Normal"], fontName="Helvetica-Bold",
                                 fontSize=12, leading=16, textColor=NAVY, alignment=TA_CENTER, spaceBefore=10, spaceAfter=4),
        "purpose": ParagraphStyle("purpose", parent=base["Normal"], fontName="Helvetica-Oblique",
                                  fontSize=11, leading=16, textColor=INK, alignment=TA_CENTER, spaceBefore=14, spaceAfter=18),
        "h1": ParagraphStyle("h1", parent=base["Heading1"], fontName="Helvetica-Bold",
                             fontSize=15, leading=19, textColor=NAVY, spaceBefore=14, spaceAfter=8),
        "h2": ParagraphStyle("h2", parent=base["Heading2"], fontName="Helvetica-Bold",
                             fontSize=12, leading=15, textColor=ACCENT, spaceBefore=11, spaceAfter=6),
        "body": ParagraphStyle("body", parent=base["Normal"], fontName="Helvetica",
                               fontSize=10, leading=14, textColor=INK, alignment=TA_JUSTIFY, spaceAfter=8),
        "bullet": ParagraphStyle("bullet", parent=base["Normal"], fontName="Helvetica",
                                 fontSize=10, leading=13, textColor=INK, leftIndent=4),
        "cell": ParagraphStyle("cell", parent=base["Normal"], fontName="Helvetica", fontSize=9, leading=11, textColor=INK),
        "code": ParagraphStyle("code", parent=base["Code"], fontName="Courier", fontSize=8.2, leading=11, textColor=INK,
                               backColor=CODE_BG, leftIndent=6, rightIndent=6, spaceBefore=4, spaceAfter=10),
        "caption": ParagraphStyle("caption", parent=base["Normal"], fontName="Helvetica-Oblique",
                                  fontSize=8.5, leading=11, textColor=MUTED, spaceAfter=10),
    }


def markup(text: str) -> str:
    """**bold**, *italic* and `code` to reportlab's mini-HTML, with links for web and mail addresses."""
    out, at = [], 0
    for match in MARKS.finditer(text):
        out.append(linked(text[at:match.start()]))
        if match.group(1) is not None:
            out.append(f"<b>{linked(match.group(1))}</b>")
        elif match.group(2) is not None:
            out.append(f"<font face='Courier'>{html.escape(match.group(2), quote=False)}</font>")
        else:
            out.append(f"<i>{linked(match.group(3))}</i>")
        at = match.end()
    out.append(linked(text[at:]))
    return "".join(out)


def linked(text: str) -> str:
    parts, at = [], 0
    for match in URL.finditer(text):
        parts.append(html.escape(text[at:match.start()], quote=False))
        target = match.group(1)
        href = target if target.startswith("http") else f"mailto:{target}"
        parts.append(f'<link href="{html.escape(href)}" color="blue"><u>{html.escape(target, quote=False)}</u></link>')
        at = match.end()
    parts.append(html.escape(text[at:], quote=False))
    return "".join(parts)


def bullets(items, style, numbered=False):
    flowables = [ListItem(Paragraph(markup(i), style), leftIndent=12, bulletColor=ACCENT) for i in items]
    if numbered:
        return ListFlowable(flowables, bulletType="1", leftIndent=18, spaceBefore=2, spaceAfter=8, bulletFontSize=10)
    return ListFlowable(flowables, bulletType="bullet", start="•", leftIndent=18, spaceBefore=2, spaceAfter=8)


def table(rows, s):
    columns = max(len(r) for r in rows)
    widths = {3: [1.7 * inch, 1.7 * inch, 3.4 * inch], 2: [2.2 * inch, 4.6 * inch]}.get(columns, [6.8 * inch / columns] * columns)
    data = [[Paragraph(("<b>%s</b>" if r == 0 else "%s") % markup(cell), s["cell"]) for cell in row] for r, row in enumerate(rows)]
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), CODE_BG),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, colors.Color(0.85, 0.88, 0.93)),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t


def figure(name, caption, s, scratch: Path, width=6.6 * inch):
    src = SHOTS / f"{name}.png"
    if not name or not src.exists():
        return []
    small = scratch / f"{name}.jpg"
    with PILImage.open(src) as img:
        img = img.convert("RGB")
        img.thumbnail((1600, 1600))
        img.save(small, "JPEG", quality=82)
    flowable = Image(str(small))
    flowable.drawHeight = width * flowable.imageHeight / flowable.imageWidth
    flowable.drawWidth = width
    return [flowable, Paragraph(markup(caption or ""), s["caption"])]


def build():
    manual = json.loads(CONTENT.read_text(encoding="utf-8"))
    s = styles()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc = SimpleDocTemplate(
        str(OUT), pagesize=letter,
        leftMargin=0.75 * inch, rightMargin=0.75 * inch, topMargin=0.7 * inch, bottomMargin=0.7 * inch,
        title=f"{manual['title']} User Manual for Windows", author="BigSkyAstro.com",
    )

    def footer(canvas, _doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(MUTED)
        canvas.drawCentredString(letter[0] / 2, 0.4 * inch,
                                 f"{manual['title']} for Windows  ·  Open-source freeware  ·  {canvas.getPageNumber()}")
        canvas.restoreState()

    story = []
    with tempfile.TemporaryDirectory(prefix="sts-manual-") as tmp:
        scratch = Path(tmp)
        story.append(Spacer(1, 0.6 * inch))
        if LOGO.exists():
            logo = Image(str(LOGO))
            logo.drawHeight = 2.6 * inch * logo.imageHeight / logo.imageWidth
            logo.drawWidth = 2.6 * inch
            story += [logo, Spacer(1, 16)]
        story.append(Paragraph(html.escape(manual["title"]), s["cover_title"]))
        story.append(Paragraph(html.escape(manual["subtitle"]), s["cover_sub"]))
        story.append(Paragraph(html.escape(manual["platform"]), s["cover_sub"]))
        story.append(Paragraph(f"<b>{html.escape(manual['notice'])}</b>", s["notice"]))
        story.append(Paragraph(markup(manual["purpose"]), s["purpose"]))
        cover = manual.get("cover") or {}
        story += figure(cover.get("image"), cover.get("caption"), s, scratch)
        story.append(PageBreak())

        for section in manual["sections"]:
            heading = Paragraph(html.escape(section["title"]), s["h1" if section.get("level", 1) == 1 else "h2"])
            flowables = []
            for block in section["blocks"]:
                kind = block.get("type", "paragraph")
                if kind in ("bullets", "numbers"):
                    flowables.append(bullets(block.get("items", []), s["bullet"], numbered=kind == "numbers"))
                elif kind == "code":
                    flowables.append(Preformatted(block.get("text", "").rstrip() + "\n", s["code"], maxLineLength=96))
                elif kind == "table":
                    flowables += [table(block.get("rows", []), s), Spacer(1, 8)]
                elif kind == "figure":
                    flowables += figure(block.get("image"), block.get("caption"), s, scratch, width=5.6 * inch)
                else:
                    flowables.append(Paragraph(markup(block.get("text", "")), s["body"]))
            # Keep each heading with its first block so a heading never ends a page.
            story.append(KeepTogether([heading] + flowables[:1]))
            story += flowables[1:]

        story += [Spacer(1, 14), Paragraph(markup(manual["end"]), s["caption"])]
        doc.build(story, onFirstPage=footer, onLaterPages=footer)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    build()
