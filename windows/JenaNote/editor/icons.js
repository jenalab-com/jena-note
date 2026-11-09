'use strict';

// Icons from Lucide 0.460.0 (https://lucide.dev), ISC license. See LICENSE-lucide.txt.
// Only the shapes are kept. They are drawn with the current text color.

const ICONS = {
  "chevrons-right": "<path d=\"m6 17 5-5-5-5\" /><path d=\"m13 17 5-5-5-5\" />",
  "a-arrow-down": "<path d=\"M3.5 13h6\" /><path d=\"m2 16 4.5-9 4.5 9\" /><path d=\"M18 7v9\" /><path d=\"m14 12 4 4 4-4\" />",
  "a-arrow-up": "<path d=\"M3.5 13h6\" /><path d=\"m2 16 4.5-9 4.5 9\" /><path d=\"M18 16V7\" /><path d=\"m14 11 4-4 4 4\" />",
  "baseline": "<path d=\"M4 20h16\" /><path d=\"m6 16 6-12 6 12\" /><path d=\"M8 12h8\" />",
  "bold": "<path d=\"M6 12h9a4 4 0 0 1 0 8H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h7a4 4 0 0 1 0 8\" />",
  "book-marked": "<path d=\"M10 2v8l3-3 3 3V2\" /><path d=\"M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H19a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H6.5a1 1 0 0 1 0-5H20\" />",
  "book-open": "<path d=\"M12 7v14\" /><path d=\"M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z\" />",
  "bookmark": "<path d=\"m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z\" />",
  "chevron-down": "<path d=\"m6 9 6 6 6-6\" />",
  "code": "<polyline points=\"16 18 22 12 16 6\" /><polyline points=\"8 6 2 12 8 18\" />",
  "file-code": "<path d=\"M10 12.5 8 15l2 2.5\" /><path d=\"m14 12.5 2 2.5-2 2.5\" /><path d=\"M14 2v4a2 2 0 0 0 2 2h4\" /><path d=\"M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z\" />",
  "heading": "<path d=\"M6 12h12\" /><path d=\"M6 20V4\" /><path d=\"M18 20V4\" />",
  "italic": "<line x1=\"19\" x2=\"10\" y1=\"4\" y2=\"4\" /><line x1=\"14\" x2=\"5\" y1=\"20\" y2=\"20\" /><line x1=\"15\" x2=\"9\" y1=\"4\" y2=\"20\" />",
  "link": "<path d=\"M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71\" /><path d=\"M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71\" />",
  "list-ordered": "<path d=\"M10 12h11\" /><path d=\"M10 18h11\" /><path d=\"M10 6h11\" /><path d=\"M4 10h2\" /><path d=\"M4 6h1v4\" /><path d=\"M6 18H4c0-1 2-2 2-3s-1-1.5-2-1\" />",
  "list": "<path d=\"M3 12h.01\" /><path d=\"M3 18h.01\" /><path d=\"M3 6h.01\" /><path d=\"M8 12h13\" /><path d=\"M8 18h13\" /><path d=\"M8 6h13\" />",
  "plus": "<path d=\"M5 12h14\" /><path d=\"M12 5v14\" />",
  "replace": "<path d=\"M14 4a2 2 0 0 1 2-2\" /><path d=\"M16 10a2 2 0 0 1-2-2\" /><path d=\"M20 2a2 2 0 0 1 2 2\" /><path d=\"M22 8a2 2 0 0 1-2 2\" /><path d=\"m3 7 3 3 3-3\" /><path d=\"M6 10V5a3 3 0 0 1 3-3h1\" /><rect x=\"2\" y=\"14\" width=\"8\" height=\"8\" rx=\"2\" />",
  "scroll-text": "<path d=\"M15 12h-5\" /><path d=\"M15 8h-5\" /><path d=\"M19 17V5a2 2 0 0 0-2-2H4\" /><path d=\"M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3\" />",
  "search": "<circle cx=\"11\" cy=\"11\" r=\"8\" /><path d=\"m21 21-4.3-4.3\" />",
  "separator-horizontal": "<line x1=\"3\" x2=\"21\" y1=\"12\" y2=\"12\" /><polyline points=\"8 8 12 4 16 8\" /><polyline points=\"16 16 12 20 8 16\" />",
  "sliders-horizontal": "<line x1=\"21\" x2=\"14\" y1=\"4\" y2=\"4\" /><line x1=\"10\" x2=\"3\" y1=\"4\" y2=\"4\" /><line x1=\"21\" x2=\"12\" y1=\"12\" y2=\"12\" /><line x1=\"8\" x2=\"3\" y1=\"12\" y2=\"12\" /><line x1=\"21\" x2=\"16\" y1=\"20\" y2=\"20\" /><line x1=\"12\" x2=\"3\" y1=\"20\" y2=\"20\" /><line x1=\"14\" x2=\"14\" y1=\"2\" y2=\"6\" /><line x1=\"8\" x2=\"8\" y1=\"10\" y2=\"14\" /><line x1=\"16\" x2=\"16\" y1=\"18\" y2=\"22\" />",
  "sparkles": "<path d=\"M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z\" /><path d=\"M20 3v4\" /><path d=\"M22 5h-4\" /><path d=\"M4 17v2\" /><path d=\"M5 18H3\" />",
  "spell-check": "<path d=\"m6 16 6-12 6 12\" /><path d=\"M8 12h8\" /><path d=\"m16 20 2 2 4-4\" />",
  "square-code": "<path d=\"M10 9.5 8 12l2 2.5\" /><path d=\"m14 9.5 2 2.5-2 2.5\" /><rect width=\"18\" height=\"18\" x=\"3\" y=\"3\" rx=\"2\" />",
  "text-quote": "<path d=\"M17 6H3\" /><path d=\"M21 12H8\" /><path d=\"M21 18H8\" /><path d=\"M3 12v6\" />",
};

function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('class', 'icon');
  svg.innerHTML = ICONS[name] ?? '';
  return svg;
}
