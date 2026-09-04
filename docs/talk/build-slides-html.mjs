#!/usr/bin/env node
// Build the talk as a single self-contained reveal.js page.
//
// The output is one file with no external requests: reveal's script and stylesheet
// are inlined, as is the esbee mark. That is the shape nsite wants -- each file
// becomes a Blossom blob and a signed manifest points a path at it, so a deck that
// is one blob is a deck that cannot half-load.
//
//   node docs/talk/build-slides-html.mjs [input.md] [output.html]

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import {
  ACCENT,
  INK,
  MUTED,
  PAPER,
  RULE,
  inlineRuns,
  isDivider,
  parseBlocks,
  stripInline,
  toSlides,
} from "./lib/slide-model.mjs";

const HERE = dirname(new URL(import.meta.url).pathname);
const ROOT = resolve(HERE, "..", "..");
const SRC = resolve(process.argv[2] ?? join(HERE, "slides-bitcoin-staking-esbee-dao.md"));
const OUT = resolve(process.argv[3] ?? join(ROOT, "site", "index.html"));

const REVEAL_VERSION = "5.1.0";
const REVEAL_FILES = ["reset.min.css", "reveal.min.css", "reveal.min.js"];
const CACHE = join(ROOT, ".cache", "reveal", REVEAL_VERSION);

// -- Vendored reveal.js -------------------------------------------------------

async function vendored(name) {
  const path = join(CACHE, name);
  if (existsSync(path)) return readFileSync(path, "utf8");

  const url = `https://cdnjs.cloudflare.com/ajax/libs/reveal.js/${REVEAL_VERSION}/${name}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url} -> ${response.status}`);
  const body = await response.text();
  mkdirSync(CACHE, { recursive: true });
  writeFileSync(path, body);
  return body;
}

// -- HTML helpers -------------------------------------------------------------

const esc = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const TAG = { b: "strong", i: "em", c: "code" };

// Markdown's inline layer, rendered rather than measured.
function inline(text) {
  return inlineRuns(text)
    .map((run) => {
      const body = esc(run.text);
      const tag = TAG[run.style];
      return tag ? `<${tag}>${body}</${tag}>` : body;
    })
    .join("");
}

const widest = (lines) => Math.max(1, ...lines.map((l) => [...l].length));

function renderBlock(block) {
  switch (block.kind) {
    case "heading":
      return `<h3>${inline(block.text)}</h3>`;

    case "para":
      return `<p>${inline(block.text)}</p>`;

    case "quote":
      return `<blockquote>${inline(block.text)}</blockquote>`;

    case "code": {
      // `data-cols` is what the fitter needs to keep a diagram inside the stage:
      // a monospace block's width is its longest line, nothing else.
      const body = block.lines.map((l) => esc(l)).join("\n");
      return `<pre data-cols="${widest(block.lines)}"><code>${body}</code></pre>`;
    }

    case "list": {
      const ordered = /^\d+\.$/.test(block.items[0]?.marker ?? "");
      const glyphs = block.items.every((i) => /^[✓✗→]$/.test(i.marker));
      const items = block.items
        .map((item) =>
          glyphs
            ? `<li><span class="glyph">${esc(item.marker)}</span>${inline(item.text)}</li>`
            : `<li>${inline(item.text)}</li>`,
        )
        .join("");
      if (ordered) return `<ol>${items}</ol>`;
      return `<ul${glyphs ? ' class="glyphs"' : ""}>${items}</ul>`;
    }

    case "table": {
      const [head, ...body] = block.rows;
      const row = (cells, tag) =>
        `<tr>${cells.map((c) => `<${tag}>${inline(c)}</${tag}>`).join("")}</tr>`;
      return (
        `<table><thead>${row(head, "th")}</thead>` +
        `<tbody>${body.map((r) => row(r, "td")).join("")}</tbody></table>`
      );
    }

    default:
      return "";
  }
}

function renderSlide(slide, mark) {
  if (slide.cover) {
    const lines = slide.blocks
      .filter((b) => b.kind === "heading" || b.kind === "para")
      .map((b) => stripInline(b.text));
    const [lead, ...rest] = lines;
    return (
      `<section><div class="slide cover">` +
      `<div class="mark">${mark}</div>` +
      `<h1>${esc(stripInline(slide.title))}</h1>` +
      (lead ? `<p class="lead">${esc(lead)}</p>` : "") +
      `<div class="rule"></div>` +
      rest.map((t) => `<p class="meta">${esc(t)}</p>`).join("") +
      `</div></section>`
    );
  }

  if (isDivider(slide)) {
    const lead = slide.blocks.map((b) => stripInline(b.text)).join(" ");
    return (
      `<section><div class="slide divider">` +
      `<h2>${esc(stripInline(slide.title))}</h2>` +
      `<div class="rule"></div>` +
      (lead ? `<p class="lead">${esc(lead)}</p>` : "") +
      `</div></section>`
    );
  }

  const kicker =
    slide.kicker && stripInline(slide.kicker) !== stripInline(slide.title)
      ? `<p class="kicker">${esc(stripInline(slide.kicker))}</p>`
      : "";

  return (
    `<section><div class="slide">` +
    `<header>${kicker}<h2>${esc(stripInline(slide.title))}</h2></header>` +
    `<div class="body"><div class="flow">${slide.blocks.map(renderBlock).join("")}</div></div>` +
    `</div></section>`
  );
}

// The mark's stylesheet uses bare class names and a `:root` rule; inlined into a
// page those would apply to the page. Scope them, and drop the theme switch --
// the deck has one look.
function scopedMark(svg) {
  return svg
    .replace(/<\?xml[^>]*\?>/g, "")
    .replace(/<style>[\s\S]*?<\/style>/, (style) => {
      const scoped = style
        .replace(/:root\s*\{[^}]*\}/g, "")
        .replace(/@media \(prefers-color-scheme: dark\) \{[\s\S]*?\n\s*\}/, "")
        .replace(/\.(cell|comb|letter|stripe)\b/g, ".mark .$1");
      return scoped;
    })
    .replace("<svg ", '<svg class="esbee" ');
}

// -- The page -----------------------------------------------------------------

const STYLE = `
:root {
  --ink: ${INK};
  --paper: ${PAPER};
  --accent: ${ACCENT};
  --muted: ${MUTED};
  --rule: ${RULE};
  --panel: #ece5d8;
  --sans: "Inter", "Helvetica Neue", Helvetica, Arial, system-ui, sans-serif;
  --mono: "DejaVu Sans Mono", "SFMono-Regular", Menlo, Consolas, monospace;
}

html, body, .reveal-viewport { background: var(--paper); }

.reveal { font-family: var(--sans); color: var(--ink); font-weight: 400; }
.reveal ::selection { background: var(--accent); color: var(--paper); }

.reveal .slides { text-align: left; }
.reveal .slides section { height: 720px; padding: 0; }
.reveal .slide {
  height: 100%;
  padding: 56px 64px 52px;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
}

.reveal h1, .reveal h2, .reveal h3 {
  font-family: var(--sans);
  font-weight: 700;
  color: var(--ink);
  text-transform: none;
  letter-spacing: -0.015em;
  margin: 0;
  line-height: 1.15;
}

.reveal header { flex: 0 0 auto; margin-bottom: 26px; }
.reveal .kicker {
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--accent);
  margin: 0 0 6px;
}
.reveal header h2 {
  font-size: 42px;
  font-weight: 700;
  padding-bottom: 14px;
  border-bottom: 1px solid var(--rule);
}

/* The fitter measures .flow against .body, so .body must not grow. */
.reveal .body { flex: 1 1 auto; min-height: 0; overflow: hidden; }
.reveal .flow { font-size: 25px; line-height: 1.45; }
.reveal .flow > * { margin: 0 0 0.7em; }
.reveal .flow > *:last-child { margin-bottom: 0; }

.reveal .flow h3 {
  font-size: 1.08em;
  color: var(--accent);
  margin: 1.1em 0 0.45em;
}
.reveal .flow h3:first-child { margin-top: 0; }

.reveal .flow strong { font-weight: 700; color: var(--ink); }
.reveal .flow em { font-style: italic; }
.reveal .flow code {
  font-family: var(--mono);
  font-size: 0.92em;
  color: var(--accent);
}

.reveal .flow ul, .reveal .flow ol { padding-left: 1.5em; margin-left: 0; }
.reveal .flow li { margin: 0 0 0.3em; }
.reveal .flow ul { list-style: none; padding-left: 1.35em; }
.reveal .flow ul > li::before {
  content: "\\2022";
  color: var(--accent);
  font-weight: 700;
  display: inline-block;
  width: 1.35em;
  margin-left: -1.35em;
}
.reveal .flow ul.glyphs > li::before { content: none; }
.reveal .flow .glyph {
  color: var(--accent);
  font-weight: 700;
  display: inline-block;
  width: 1.35em;
  margin-left: -1.35em;
}
.reveal .flow ol { list-style: none; counter-reset: step; padding-left: 1.6em; }
.reveal .flow ol > li { counter-increment: step; }
.reveal .flow ol > li::before {
  content: counter(step) ".";
  color: var(--accent);
  font-weight: 700;
  display: inline-block;
  width: 1.6em;
  margin-left: -1.6em;
}

.reveal .flow pre {
  font-family: var(--mono);
  background: var(--panel);
  border-radius: 6px;
  padding: 0.75em 1em;
  margin: 0.8em 0;
  box-shadow: none;
  width: auto;
  max-height: none;
  overflow: visible;
  word-wrap: normal;
}
.reveal .flow pre code {
  font-family: var(--mono);
  font-size: inherit;
  color: var(--ink);
  line-height: 1.4;
  display: block;
  white-space: pre;
  padding: 0;
  word-wrap: normal;
  /* reveal clips pre code with !important; a diagram that overruns should be
     visible rather than silently cut. */
  overflow: visible !important;
  max-height: none;
}

.reveal .flow blockquote {
  font-style: italic;
  color: var(--muted);
  background: none;
  box-shadow: none;
  border-left: 3px solid var(--accent);
  padding: 0.1em 0 0.1em 0.9em;
  margin: 0.8em 0;
  width: auto;
}

.reveal .flow table { width: 100%; border-collapse: collapse; margin: 0.5em 0 0.8em; }
.reveal .flow th {
  text-align: left;
  font-size: 0.8em;
  font-weight: 700;
  letter-spacing: 0.07em;
  text-transform: uppercase;
  color: var(--accent);
  border-bottom: 1px solid var(--rule);
  padding: 0 1em 0.5em 0;
}
.reveal .flow td {
  vertical-align: top;
  padding: 0.42em 1em 0.42em 0;
  border-bottom: 1px solid rgba(0, 0, 0, 0.05);
}
.reveal .flow tr:last-child td { border-bottom: none; }
.reveal .flow td:last-child, .reveal .flow th:last-child { padding-right: 0; }

.reveal .cover, .reveal .divider {
  align-items: center;
  justify-content: center;
  text-align: center;
}
.reveal .cover h1 { font-size: 68px; font-weight: 700; }
.reveal .cover .lead { font-size: 27px; color: var(--muted); margin: 14px 0 0; max-width: 24em; }
.reveal .cover .meta { font-size: 20px; color: var(--muted); margin: 6px 0 0; }
.reveal .cover .mark { width: 112px; margin-bottom: 30px; }
.reveal .cover .mark svg { width: 100%; height: auto; display: block; }
.reveal .divider h2 { font-size: 52px; font-weight: 700; }
.reveal .divider .lead { font-size: 24px; color: var(--muted); margin: 0; max-width: 26em; }
.reveal .rule {
  width: 88px;
  height: 3px;
  background: var(--accent);
  margin: 22px 0;
  border-radius: 2px;
}

.reveal .progress { color: var(--accent); height: 3px; }
.reveal .slide-number {
  background: none;
  color: var(--muted);
  font-family: var(--sans);
  font-size: 15px;
  right: 64px;
  bottom: 34px;
}
.reveal .slide-number a { color: inherit; text-decoration: none; }
.reveal .controls { color: var(--accent); }

@media print {
  .reveal .slide-number { display: block; }
}
`;

// Shrink each slide to fit rather than trusting an estimate: the browser knows
// what the text actually measures, and a talk cannot afford a clipped diagram.
const FITTER = `
(function () {
  var MAX = 25, MIN = 11, SLACK = 12; // a panel flush with the frame reads as cut off

  function fit(section) {
    var body = section.querySelector('.body');
    var flow = section.querySelector('.flow');
    if (!body || !flow || !body.clientHeight) return false;

    var width = body.clientWidth;
    var pres = flow.querySelectorAll('pre');
    for (var i = 0; i < pres.length; i++) {
      // 0.6 em per character is the advance of every monospace face we fall
      // back to; 2.2em covers the panel's own padding.
      var cols = parseInt(pres[i].getAttribute('data-cols'), 10) || 40;
      pres[i].__cap = (width - 2.2 * 16) / (cols * 0.6);
    }

    function apply(size) {
      flow.style.fontSize = size + 'px';
      for (var i = 0; i < pres.length; i++) {
        // Whole pixels: a fractional monospace size rounds each glyph cell
        // independently and opens gaps between the box-drawing corners.
        var px = Math.max(9, Math.floor(Math.min(pres[i].__cap, size * 0.95)));
        pres[i].style.fontSize = px + 'px';
      }
    }

    var room = body.clientHeight - SLACK;
    var size = MAX;
    apply(size);
    while (size > MIN && flow.scrollHeight > room) {
      size -= 0.5;
      apply(size);
    }
    section.setAttribute('data-fitted', '');
    return true;
  }

  function fitAll() {
    var sections = document.querySelectorAll('.reveal .slides section');
    for (var i = 0; i < sections.length; i++) {
      if (!sections[i].hasAttribute('data-fitted')) fit(sections[i]);
    }
  }

  function fitSoon() {
    fitAll();
    requestAnimationFrame(fitAll);
  }
  window.__fitSoon = fitSoon;

  window.__fitSlides = fitAll;
  window.addEventListener('resize', function () {
    var sections = document.querySelectorAll('.reveal .slides section[data-fitted]');
    for (var i = 0; i < sections.length; i++) sections[i].removeAttribute('data-fitted');
    fitAll();
  });
})();
`;

// -- Run ----------------------------------------------------------------------

const [reset, revealCss, revealJs] = await Promise.all(REVEAL_FILES.map(vendored));

const md = readFileSync(SRC, "utf8");
const slides = toSlides(parseBlocks(md));
const mark = scopedMark(readFileSync(join(ROOT, "brand", "esbee.svg"), "utf8"));

const title = stripInline(slides[0]?.title ?? "Slides");
const description = stripInline(
  slides[0]?.blocks.find((b) => b.kind === "heading")?.text ?? "",
);

// The mark doubles as the tab icon; a data URI keeps the page to one request.
const favicon =
  "data:image/svg+xml," +
  encodeURIComponent(
    readFileSync(join(ROOT, "brand", "esbee.svg"), "utf8").replace(/\n\s*/g, " "),
  );

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="icon" href="${favicon}">
<style>${reset}</style>
<style>${revealCss}</style>
<style>${STYLE}</style>
</head>
<body>
<div class="reveal">
<div class="slides">
${slides.map((slide) => renderSlide(slide, mark)).join("\n")}
</div>
</div>
<script>${revealJs}</script>
<script>${FITTER}</script>
<script>
var deck = Reveal.initialize({
  width: 1280,
  height: 720,
  margin: 0.02,
  minScale: 0.2,
  maxScale: 1.6,
  center: false,
  hash: true,
  slideNumber: 'c/t',
  transition: 'fade',
  transitionSpeed: 'fast',
  viewDistance: 99,
  controls: true,
  progress: true,
});
deck.then(function () { window.__fitSoon(); });
Reveal.on('ready', function () { window.__fitSoon(); });
Reveal.on('slidechanged', function () { window.__fitSoon(); });
window.addEventListener('load', function () { window.__fitSoon(); });
</script>
</body>
</html>
`;

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, html, "utf8");

console.log(
  `${slides.length} slides -> ${OUT} (${(Buffer.byteLength(html) / 1024).toFixed(0)} KB, self-contained)`,
);
