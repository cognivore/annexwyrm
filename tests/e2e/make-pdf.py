#!/usr/bin/env python3
"""Emit a minimal but valid single-page PDF on stdout.

Pure stdlib; no reportlab, no pandoc, no ghostscript. Useful for the
e2e tests where we just need *something* that says "PDF" to a parser
and renders one line of text.

Usage:
    make-pdf.py "Title of this PDF"
"""

from __future__ import annotations
import sys


def make_pdf(title: str) -> bytes:
    # Five PDF objects: catalog, pages, page, font, content stream.
    # Each object's byte offset goes into the xref table, so we build
    # them sequentially and remember where each starts.
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            b"<< /Type /Page /Parent 2 0 R "
            b"/Resources << /Font << /F1 4 0 R >> >> "
            b"/MediaBox [0 0 612 792] /Contents 5 0 R >>"
        ),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]

    # Content stream: set font Helvetica@24, text origin (72, 700), show title.
    # Escape `(`, `)`, `\` per PDF string syntax (we keep it ASCII-only).
    safe_title = (
        title.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    )
    stream = (
        b"BT /F1 24 Tf 72 700 Td (" + safe_title.encode("ascii") + b") Tj ET"
    )
    objects.append(
        b"<< /Length "
        + str(len(stream)).encode()
        + b" >>\nstream\n"
        + stream
        + b"\nendstream"
    )

    pdf = bytearray(b"%PDF-1.4\n")
    offsets: list[int] = []
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(pdf))
        pdf += f"{i} 0 obj\n".encode()
        pdf += obj
        pdf += b"\nendobj\n"

    xref_offset = len(pdf)
    pdf += b"xref\n0 " + f"{len(objects) + 1}\n".encode()
    pdf += b"0000000000 65535 f \n"
    for off in offsets:
        pdf += f"{off:010d} 00000 n \n".encode()
    pdf += (
        b"trailer << /Size "
        + str(len(objects) + 1).encode()
        + b" /Root 1 0 R >>\n"
        b"startxref\n"
        + str(xref_offset).encode()
        + b"\n%%EOF\n"
    )
    return bytes(pdf)


if __name__ == "__main__":
    title = sys.argv[1] if len(sys.argv) > 1 else "Untitled"
    sys.stdout.buffer.write(make_pdf(title))
