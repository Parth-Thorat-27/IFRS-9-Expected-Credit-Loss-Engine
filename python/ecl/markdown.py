"""Tiny Markdown table writer for the generated docs (no extra dependency)."""
from __future__ import annotations

from typing import Iterable, Sequence


def table(headers: Sequence[str], rows: Iterable[Sequence[object]], right: Sequence[int] = ()) -> str:
    """Return a GitHub Markdown table. `right` lists column indexes to right-align (numbers)."""
    align = ["---:" if i in right else "---" for i in range(len(headers))]
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(align) + " |"]
    lines += ["| " + " | ".join(str(v) for v in row) + " |" for row in rows]
    return "\n".join(lines)
