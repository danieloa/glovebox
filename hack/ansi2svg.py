#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
ansi2svg — render captured ANSI terminal output to a self-contained SVG.

Produces the terminal images in the README. SVG rather than PNG so they stay
crisp at any zoom, weigh a few KB, and diff as text in review — you can read a
commit and see exactly what changed in a screenshot, which you cannot do with a
binary blob.

The images are generated from a real cluster by hack/make-screenshots.sh, not
retouched by hand. That matters for a repo whose whole pitch is diagnostic
output: a screenshot nobody can regenerate is a marketing asset, not evidence.

    kt-net shop | hack/ansi2svg.py --title "kt-net shop" > out.svg

Handles the small SGR subset the toolkit actually emits — bold, dim, and the
eight basic foreground colours. Anything else is dropped rather than rendered
wrong.
"""
import argparse, html, re, sys

# Dark in both GitHub themes, deliberately: terminal output should read as
# terminal output, and a light-background image would look wrong against the
# dark README it usually sits in.
BG, FG, DIM = "#161822", "#c8d0e0", "#717892"
COLORS = {
    30: "#4b5263", 31: "#f7768e", 32: "#9ece6a", 33: "#e0af68",
    34: "#7aa2f7", 35: "#bb9af7", 36: "#7dcfff", 37: "#c8d0e0",
}

# CHAR_W is used ONLY to size the canvas, never to place text. Monospace faces
# vary between about 0.60 and 0.63 em of advance (Menlo, SF Mono, Consolas,
# DejaVu Sans Mono are all in that band), and the first version of this placed
# each coloured run at an arithmetic x — which clipped the longest line off the
# right edge as soon as the viewer's font was a shade wider than assumed.
#
# Runs are now tspans inside one text element per line, so the font advances
# itself and alignment is correct whatever face the browser picks. The estimate
# below is deliberately at the generous end of the band so nothing clips.
CHAR_W, LINE_H, FONT_SIZE = 8.4, 19.0, 13.0
PAD_X, PAD_TOP, PAD_BOT, TITLEBAR = 18.0, 14.0, 16.0, 30.0

SGR = re.compile(r"\x1b\[([0-9;]*)m")


def spans(line):
    """Split one line into (text, colour, bold, dim) runs."""
    out, pos, color, bold, dim = [], 0, None, False, False
    for m in SGR.finditer(line):
        if m.start() > pos:
            out.append((line[pos:m.start()], color, bold, dim))
        for code in (int(c) for c in (m.group(1) or "0").split(";") if c != ""):
            if code == 0:        color, bold, dim = None, False, False
            elif code == 1:      bold = True
            elif code == 2:      dim = True
            elif code in COLORS: color = COLORS[code]
        pos = m.end()
    if pos < len(line):
        out.append((line[pos:], color, bold, dim))
    return out


def render(text, title):
    lines = [l.rstrip("\n") for l in text.rstrip("\n").split("\n")]
    parsed = [spans(l) for l in lines]
    widest = max((sum(len(t) for t, *_ in p) for p in parsed), default=40)
    # The title bar has to fit too, or a long command overflows the frame.
    width  = max(widest, len(title) + 8) * CHAR_W + PAD_X * 2
    height = TITLEBAR + PAD_TOP + len(lines) * LINE_H + PAD_BOT

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" '
         f'height="{height:.0f}" viewBox="0 0 {width:.0f} {height:.0f}" '
         f'font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace" '
         f'font-size="{FONT_SIZE}">',
         f'<rect width="{width:.0f}" height="{height:.0f}" rx="8" fill="{BG}"/>',
         f'<rect width="{width:.0f}" height="{TITLEBAR}" rx="8" fill="#20232f"/>',
         f'<rect y="{TITLEBAR-8}" width="{width:.0f}" height="8" fill="#20232f"/>']
    for i, c in enumerate(("#f7768e", "#e0af68", "#9ece6a")):
        o.append(f'<circle cx="{18+i*15}" cy="{TITLEBAR/2}" r="5" fill="{c}"/>')
    o.append(f'<text x="{width/2:.0f}" y="{TITLEBAR/2+4:.0f}" fill="{DIM}" '
             f'text-anchor="middle" font-size="11.5">{html.escape(title)}</text>')

    y = TITLEBAR + PAD_TOP + FONT_SIZE
    for runs in parsed:
        # One <text> per line with a <tspan> per coloured run: the font lays the
        # runs out end to end itself, so nothing depends on guessing its metrics.
        parts = []
        for text_, color, bold, dim in runs:
            attrs = ""
            if color:  attrs += f' fill="{color}"'
            elif dim:  attrs += f' fill="{DIM}"'
            if bold:   attrs += ' font-weight="600"'
            parts.append(f'<tspan{attrs}>{html.escape(text_)}</tspan>')
        o.append(f'<text x="{PAD_X}" y="{y:.1f}" fill="{FG}" '
                 f'xml:space="preserve">{"".join(parts)}</text>')
        y += LINE_H
    o.append("</svg>")
    return "\n".join(o)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", default="glovebox")
    a = ap.parse_args()
    sys.stdout.write(render(sys.stdin.read(), a.title))
