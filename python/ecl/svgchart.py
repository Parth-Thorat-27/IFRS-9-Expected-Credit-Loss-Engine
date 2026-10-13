"""Small inline-SVG charts for the HTML report: no image files, no JS library.

The rules they follow: one y-axis per chart; thin marks (columns at most 24px
wide with a 4px rounded top, 2px lines, 8px end dots with a 2px surface ring);
a 2px surface gap between stacked segments; hairline gridlines; a legend for
two or more series plus a few direct labels, never a number on every mark.
Every mark carries its values in data attributes for the page's hover and
keyboard tooltip. Colours are CSS variables (--series-1, --grid, ...), so the
page's light and dark tokens restyle the charts without touching the SVG.
"""
from __future__ import annotations

import json
import math
from html import escape
from typing import Callable, Sequence

WIDTH, HEIGHT = 520, 280
LEFT, RIGHT, TOP, BOTTOM = 56, 96, 16, 36   # room for y ticks, end labels and x labels
COLUMN = 24        # column width (px)
GAP = 2            # surface gap between stacked segments (px)
RADIUS = 4         # rounded data end (px)


def money(value: float) -> str:
    """Compact dollars: $57.6M, $820K, $950."""
    size = abs(value)
    for limit, suffix in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if size >= limit:
            return f"${value / limit:,.1f}{suffix}".replace(".0" + suffix, suffix)
    return f"${value:,.0f}"


def percent(value: float) -> str:
    return f"{value:.1%}"


def nice_ticks(top: float, count: int = 5) -> list[float]:
    """Round tick values from 0 to at least `top` (steps of 1, 2, 2.5 or 5 x 10^k)."""
    if top <= 0:
        return [0.0, 1.0]
    raw = top / (count - 1)
    magnitude = 10 ** math.floor(math.log10(raw))
    step = next(m * magnitude for m in (1, 2, 2.5, 5, 10) if m * magnitude >= raw)
    return [i * step for i in range(int(math.ceil(top / step)) + 1)]


def _frame(ticks: list[float], fmt: Callable[[float], str], x_labels: Sequence[str],
           x_positions: Sequence[float], y_of: Callable[[float], float]) -> list[str]:
    parts = []
    for tick in ticks:
        y = y_of(tick)
        parts.append(f'<line class="grid" x1="{LEFT}" x2="{WIDTH - RIGHT}" y1="{y:.1f}" y2="{y:.1f}"/>')
        parts.append(f'<text class="tick" x="{LEFT - 8}" y="{y + 4:.1f}" text-anchor="end">{escape(fmt(tick))}</text>')
    base = y_of(0)
    parts.append(f'<line class="axis" x1="{LEFT}" x2="{WIDTH - RIGHT}" y1="{base:.1f}" y2="{base:.1f}"/>')
    for label, x in zip(x_labels, x_positions):
        parts.append(f'<text class="tick" x="{x:.1f}" y="{HEIGHT - BOTTOM + 18}" text-anchor="middle">{escape(label)}</text>')
    return parts


def _x_positions(n: int) -> list[float]:
    band = (WIDTH - LEFT - RIGHT) / n
    return [LEFT + band * (i + 0.5) for i in range(n)]


def _rounded_top(x: float, y: float, w: float, h: float, r: float) -> str:
    """Path for a rectangle with rounded top corners and a square base."""
    r = min(r, h / 2, w / 2)
    return (f"M{x:.1f},{y + h:.1f} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} "
            f"H{x + w - r:.1f} Q{x + w:.1f},{y:.1f} {x + w:.1f},{y + r:.1f} V{y + h:.1f} Z")


def stacked_columns(title: str, x_labels: Sequence[str], series: Sequence[dict],
                    fmt: Callable[[float], str] = money) -> str:
    """series: [{"name": ..., "values": [...], "color": "var(--series-1)"}, ...] stacked bottom-up."""
    totals = [sum(s["values"][i] for s in series) for i in range(len(x_labels))]
    ticks = nice_ticks(max(totals))
    plot_h = HEIGHT - TOP - BOTTOM

    def y_of(v: float) -> float:
        return TOP + plot_h - v / ticks[-1] * plot_h

    xs = _x_positions(len(x_labels))
    parts = [f'<svg class="chart" viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-label="{escape(title)}">']
    parts += _frame(ticks, fmt, x_labels, xs, y_of)
    for i, x in enumerate(xs):
        running = 0.0
        tip = json.dumps({"title": x_labels[i],
                          "rows": [[s["name"], fmt(s["values"][i]), s["color"]] for s in reversed(series)]
                          + [["Total", fmt(totals[i]), ""]]})
        visible = [s for s in series if s["values"][i] > 0]
        for s in visible:
            value = s["values"][i]
            y_top, y_bottom = y_of(running + value), y_of(running)
            running += value
            # The 2px gap is taken off the top of every segment except the last,
            # so neighbours separate by surface colour, not by an outline.
            is_last = s is visible[-1]
            h = max(y_bottom - y_top - (0 if is_last else GAP), 0.5)
            x0 = x - COLUMN / 2
            shape = (f'd="{_rounded_top(x0, y_top, COLUMN, h, RADIUS)}"' if is_last
                     else f'd="M{x0:.1f},{y_top + GAP:.1f} h{COLUMN} v{h:.1f} h-{COLUMN} Z"')
            parts.append(f'<path class="mark" {shape} fill="{s["color"]}" tabindex="0" '
                         f"data-tip='{escape(tip, quote=True)}'/>")
    # One direct label: the latest total, where the reader's eye ends.
    parts.append(f'<text class="value" x="{xs[-1]:.1f}" y="{y_of(totals[-1]) - 8:.1f}" '
                 f'text-anchor="middle">{escape(fmt(totals[-1]))}</text>')
    parts.append("</svg>")
    return "\n".join(parts)


def lines(title: str, x_labels: Sequence[str], series: Sequence[dict],
          fmt: Callable[[float], str] = percent, y_top: float | None = None) -> str:
    """series: [{"name": ..., "values": [...], "color": ...}]; crosshair tooltip over the plot."""
    ticks = nice_ticks(y_top if y_top is not None else max(max(s["values"]) for s in series))
    plot_h = HEIGHT - TOP - BOTTOM

    def y_of(v: float) -> float:
        return TOP + plot_h - v / ticks[-1] * plot_h

    xs = _x_positions(len(x_labels))
    parts = [f'<svg class="chart" viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-label="{escape(title)}">']
    parts += _frame(ticks, fmt, x_labels, xs, y_of)
    for s in series:
        points = " ".join(f"{x:.1f},{y_of(v):.1f}" for x, v in zip(xs, s["values"]))
        parts.append(f'<polyline class="line" points="{points}" stroke="{s["color"]}"/>')
    for s in series:
        # End dot (r 4 = 8px, with a 2px surface ring) and a direct label: name and latest value.
        x_end, y_end = xs[-1], y_of(s["values"][-1])
        parts.append(f'<circle class="dot" cx="{x_end:.1f}" cy="{y_end:.1f}" r="4" fill="{s["color"]}"/>')
        parts.append(f'<text class="label" x="{x_end + 10:.1f}" y="{y_end + 4:.1f}">'
                     f'{escape(s["name"])} {escape(fmt(s["values"][-1]))}</text>')
    crosshair = json.dumps({"x": [round(x, 1) for x in xs], "labels": list(x_labels),
                            "series": [{"name": s["name"], "color": s["color"],
                                        "values": [fmt(v) for v in s["values"]]} for s in series]})
    parts.append(f'<line class="crosshair" x1="0" x2="0" y1="{TOP}" y2="{HEIGHT - BOTTOM}" visibility="hidden"/>')
    # The whole plot area is the hit target: the crosshair snaps to the nearest month.
    parts.append(f'<rect class="hit" x="{LEFT}" y="{TOP}" width="{WIDTH - LEFT - RIGHT}" height="{plot_h}" '
                 f"tabindex=\"0\" data-crosshair='{escape(crosshair, quote=True)}'/>")
    parts.append("</svg>")
    return "\n".join(parts)


def legend(series: Sequence[dict], kind: str = "rect") -> str:
    """Legend mirrors the mark: a square for columns, a short line for lines."""
    items = []
    for s in series:
        key = (f'<span class="key-rect" style="background:{s["color"]}"></span>' if kind == "rect"
               else f'<span class="key-line" style="background:{s["color"]}"></span>')
        items.append(f'<span class="legend-item">{key}{escape(s["name"])}</span>')
    return f'<div class="legend">{"".join(items)}</div>'


TOOLTIP_SCRIPT = """
(() => {
  const tip = document.getElementById('tip');
  const row = (label, value, color) => {
    const r = document.createElement('div'); r.className = 'tip-row';
    const key = document.createElement('span'); key.className = 'tip-key';
    if (color) key.style.background = color;
    const v = document.createElement('strong'); v.textContent = value;
    const l = document.createElement('span'); l.textContent = label;
    r.append(key, v, l); return r;
  };
  const show = (x, y, title, rows) => {
    tip.replaceChildren();
    const t = document.createElement('div'); t.className = 'tip-title'; t.textContent = title;
    tip.append(t, ...rows.map(r => row(...r)));
    tip.hidden = false;
    const w = tip.offsetWidth, h = tip.offsetHeight;
    tip.style.left = Math.min(x + 14, window.innerWidth - w - 8) + 'px';
    tip.style.top = Math.max(y - h - 10, 8) + 'px';
  };
  const hide = () => { tip.hidden = true; };
  document.querySelectorAll('[data-tip]').forEach(el => {
    const d = JSON.parse(el.dataset.tip);
    el.addEventListener('pointermove', e => show(e.clientX, e.clientY, d.title, d.rows));
    el.addEventListener('pointerleave', hide);
    el.addEventListener('focus', () => { const b = el.getBoundingClientRect(); show(b.right, b.top, d.title, d.rows); });
    el.addEventListener('blur', hide);
  });
  document.querySelectorAll('[data-crosshair]').forEach(hit => {
    const d = JSON.parse(hit.dataset.crosshair);
    const svg = hit.ownerSVGElement, line = svg.querySelector('.crosshair');
    let index = d.x.length - 1;
    const at = (i, x, y) => {
      index = i;
      line.setAttribute('x1', d.x[i]); line.setAttribute('x2', d.x[i]);
      line.setAttribute('visibility', 'visible');
      show(x, y, d.labels[i], d.series.map(s => [s.name, s.values[i], s.color]));
    };
    hit.addEventListener('pointermove', e => {
      const p = svg.createSVGPoint(); p.x = e.clientX; p.y = e.clientY;
      const vx = p.matrixTransform(svg.getScreenCTM().inverse()).x;
      let best = 0;
      d.x.forEach((x, i) => { if (Math.abs(x - vx) < Math.abs(d.x[best] - vx)) best = i; });
      at(best, e.clientX, e.clientY);
    });
    hit.addEventListener('pointerleave', () => { line.setAttribute('visibility', 'hidden'); hide(); });
    hit.addEventListener('keydown', e => {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      const i = Math.max(0, Math.min(d.x.length - 1, index + (e.key === 'ArrowRight' ? 1 : -1)));
      const b = hit.getBoundingClientRect(); at(i, b.left + b.width * (i + 0.5) / d.x.length, b.top);
    });
    hit.addEventListener('focus', () => { const b = hit.getBoundingClientRect(); at(index, b.right - 40, b.top); });
    hit.addEventListener('blur', () => { line.setAttribute('visibility', 'hidden'); hide(); });
  });
})();
"""
