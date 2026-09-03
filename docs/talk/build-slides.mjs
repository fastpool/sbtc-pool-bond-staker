#!/usr/bin/env node
// Build a 16:9 slide deck PDF from the talk's markdown.
//
// There is no Impress on the build box, only Writer, so the deck is emitted as
// a flat ODF *text* document whose page is slide-shaped: one page per slide,
// hard break between them, and a fixed monospace grid so the ASCII diagrams
// that carry most of this talk land exactly as written.
//
//   node docs/talk/build-slides.mjs [input.md] [output.pdf]

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
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
const SRC = resolve(process.argv[2] ?? join(HERE, "slides-bitcoin-staking-esbee-dao.md"));
const OUT = resolve(process.argv[3] ?? SRC.replace(/\.md$/, ".pdf"));

// -- Page geometry, in points -------------------------------------------------
// 10in x 5.625in is 16:9. Everything below is derived from it.
const PAGE_W = 720;
const PAGE_H = 405;
const MARGIN_X = 40;
const MARGIN_TOP = 30;
const MARGIN_BOTTOM = 26;

const CONTENT_W = PAGE_W - 2 * MARGIN_X; // 640pt
const HEADER_H = 60; // kicker + title + rule + the gap under it
const FOOTER_H = 32; // the running footer plus a little slack against rounding
const CONTENT_H = PAGE_H - MARGIN_TOP - MARGIN_BOTTOM - HEADER_H - FOOTER_H;

// DejaVu Sans Mono advances at 0.6023em; the proportional face averages nearer
// half that at the sizes used here.
const MONO_ADVANCE = 0.6023;
const TEXT_ADVANCE = 0.58;
const LINE_FACTOR = 1.3;

const FONT_SIZES = [15, 14, 13, 12, 11, 10, 9, 8];

const MONO = "DejaVu Sans Mono";
const SANS = "DejaVu Sans";

const monoCols = (fs) => Math.floor(CONTENT_W / (MONO_ADVANCE * fs));
const textCols = (fs) => Math.floor(CONTENT_W / (TEXT_ADVANCE * fs));
const rows = (fs) => Math.floor(CONTENT_H / (LINE_FACTOR * fs));

// Word-wrap a run list to `width` columns. Words are split on whitespace only:
// a style boundary inside a word (bold text followed by a bracket, say) is not
// a place a line may break.
function wrapRuns(runs, width) {
  const words = [];
  let word = null;
  for (const run of runs) {
    const parts = run.text.split(/(\s+)/);
    for (const part of parts) {
      if (part === "") continue;
      if (/^\s+$/.test(part)) {
        word = null;
        continue;
      }
      if (!word) {
        word = { frags: [], length: 0 };
        words.push(word);
      }
      word.frags.push({ text: part, style: run.style });
      word.length += part.length;
    }
  }

  const out = [];
  let line = [];
  let len = 0;
  for (const w of words) {
    if (len > 0 && len + 1 + w.length > width) {
      out.push(line);
      line = [];
      len = 0;
    }
    if (len > 0) {
      line.push({ text: " ", style: "" });
      len += 1;
    }
    line.push(...w.frags);
    len += w.length;
  }
  if (line.length) out.push(line);
  return out.length ? out : [[]];
}

// -- Blocks -> laid-out lines -------------------------------------------------

function layout(slide, fs) {
  const cols = textCols(fs);
  const mcols = monoCols(fs);
  const lines = [];
  const blank = () => {
    if (lines.length) lines.push({ type: "blank", runs: [] });
  };

  let group = 0;
  for (const block of slide.blocks) {
    group++;
    switch (block.kind) {
      case "heading": {
        blank();
        lines.push({ type: "sub", runs: [{ text: stripInline(block.text), style: "" }] });
        break;
      }
      case "para": {
        blank();
        for (const line of wrapRuns(inlineRuns(block.text), cols)) {
          lines.push({ type: "text", runs: line });
        }
        break;
      }
      case "quote": {
        blank();
        for (const line of wrapRuns(inlineRuns(block.text), cols - 3)) {
          lines.push({ type: "quote", runs: line, indent: 3 });
        }
        break;
      }
      case "list": {
        blank();
        for (const item of block.items) {
          const pad = item.marker.length + 1;
          const wrapped = wrapRuns(inlineRuns(item.text), cols - pad - 1);
          wrapped.forEach((line, idx) => {
            lines.push({
              type: "text",
              runs:
                idx === 0
                  ? [{ text: item.marker + " ", style: "accent" }, ...line]
                  : line,
              indent: idx === 0 ? 1 : 1 + pad,
            });
          });
        }
        break;
      }
      case "code": {
        blank();
        for (const line of block.lines) {
          lines.push({ type: "code", runs: [{ text: line, style: "" }], group });
        }
        break;
      }
      case "table": {
        blank();
        for (const line of renderTable(block.rows, mcols)) lines.push({ ...line, group });
        break;
      }
      default:
        break;
    }
  }

  while (lines.length && lines[lines.length - 1].type === "blank") lines.pop();
  return lines;
}

// Tables are drawn on the same monospace grid as the diagrams: it keeps the
// column rule honest and avoids Writer's table styling entirely.
function renderTable(rowsIn, width) {
  const cells = rowsIn.map((r) => r.map(stripInline));
  const cols = Math.max(...cells.map((r) => r.length));
  const natural = [];
  for (let c = 0; c < cols; c++) {
    natural.push(Math.max(...cells.map((r) => (r[c] ?? "").length), 3));
  }

  const gap = 2;
  const budget = width - gap * (cols - 1);

  // A column can wrap, but never below its longest single word: a cell line
  // wider than its column shunts every column after it out of alignment.
  const floors = [];
  for (let c = 0; c < cols; c++) {
    floors.push(
      Math.max(
        3,
        ...cells.map((r) => Math.max(0, ...(r[c] ?? "").split(/\s+/).map((w) => w.length))),
      ),
    );
  }

  const widths = natural.slice();
  let total = widths.reduce((a, b) => a + b, 0);
  let shrinkable = true;
  while (total > budget && shrinkable) {
    shrinkable = false;
    // Take from whichever column has the most slack over its floor.
    let pick = -1;
    let slack = 0;
    for (let c = 0; c < cols; c++) {
      if (widths[c] - floors[c] > slack) {
        slack = widths[c] - floors[c];
        pick = c;
      }
    }
    if (pick >= 0) {
      widths[pick]--;
      total--;
      shrinkable = true;
    }
  }

  const out = [];
  cells.forEach((row, rowIdx) => {
    const wrapped = row.map((cell, c) => wrapPlain(cell, widths[c] ?? 8));
    const height = Math.max(...wrapped.map((w) => w.length));
    for (let line = 0; line < height; line++) {
      const text = wrapped
        .map((w, c) => (w[line] ?? "").padEnd(widths[c] ?? 8))
        .join(" ".repeat(gap))
        .replace(/\s+$/, "");
      out.push({ type: rowIdx === 0 ? "thead" : "code", runs: [{ text, style: "" }] });
    }
    if (rowIdx === 0) {
      const rule = widths.map((w) => "─".repeat(w)).join("─".repeat(gap));
      out.push({ type: "trule", runs: [{ text: rule, style: "" }] });
    }
  });
  return out;
}

function wrapPlain(text, width) {
  const words = text.split(/\s+/).filter(Boolean);
  const out = [];
  let line = "";
  for (const word of words) {
    if (line === "") line = word;
    else if (line.length + 1 + word.length <= width) line += " " + word;
    else {
      out.push(line);
      line = word;
    }
  }
  out.push(line);
  return out;
}

// -- Fitting ------------------------------------------------------------------

function tableFloor(rowsIn) {
  const cells = rowsIn.map((r) => r.map(stripInline));
  const cols = Math.max(...cells.map((r) => r.length));
  let total = 2 * (cols - 1);
  for (let c = 0; c < cols; c++) {
    total += Math.max(
      3,
      ...cells.map((r) => Math.max(0, ...(r[c] ?? "").split(/\s+/).map((w) => w.length))),
    );
  }
  return total;
}

function fit(slide) {
  const codeWidth = Math.max(
    0,
    ...slide.blocks
      .filter((b) => b.kind === "code")
      .flatMap((b) => b.lines.map((l) => l.length)),
    ...slide.blocks.filter((b) => b.kind === "table").map((b) => tableFloor(b.rows)),
  );

  // Largest size at which the widest diagram still fits the column.
  let fs = FONT_SIZES.find((size) => codeWidth === 0 || monoCols(size) >= codeWidth);
  fs = fs ?? FONT_SIZES[FONT_SIZES.length - 1];

  // Then, if it would spill, step down until it fits on one page.
  for (const size of FONT_SIZES.filter((s) => s <= fs)) {
    if (layout(slide, size).length <= rows(size)) return { fs: size, lines: layout(slide, size) };
  }
  return { fs, lines: layout(slide, fs) };
}

function paginate(slides) {
  const pages = [];
  for (const slide of slides) {
    if (isDivider(slide)) {
      pages.push({ ...slide, divider: true, fs: 15, lines: [] });
      continue;
    }
    if (slide.cover) {
      pages.push({ ...slide, fs: 15, lines: layout(slide, 15) });
      continue;
    }
    const { fs, lines } = fit(slide);
    const limit = rows(fs);
    if (lines.length <= limit) {
      pages.push({ ...slide, fs, lines });
      continue;
    }
    let start = 0;
    let part = 0;
    while (start < lines.length) {
      let end = Math.min(start + limit, lines.length);
      // Do not cut through a diagram or a table if the whole of it would fit on
      // a page of its own.
      if (end < lines.length) {
        const straddling = lines[end].group;
        if (straddling && lines[end - 1].group === straddling) {
          let groupStart = end;
          while (groupStart > start && lines[groupStart - 1].group === straddling) groupStart--;
          const groupEnd = lines.findIndex((l, i) => i >= end && l.group !== straddling);
          const groupLength = (groupEnd === -1 ? lines.length : groupEnd) - groupStart;
          if (groupStart > start && groupLength <= limit) end = groupStart;
        }
      }
      let chunk = lines.slice(start, end);
      while (chunk.length && chunk[0].type === "blank") chunk.shift();
      while (chunk.length && chunk[chunk.length - 1].type === "blank") chunk.pop();
      pages.push({
        ...slide,
        title: part === 0 ? slide.title : `${slide.title} (cont.)`,
        fs,
        lines: chunk,
      });
      start = end;
      part++;
    }
  }
  return pages;
}

// -- Flat ODF emission --------------------------------------------------------

const esc = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Writer collapses runs of spaces unless they are spelled out.
function escPreserve(s) {
  let out = "";
  let i = 0;
  while (i < s.length) {
    if (s[i] === " ") {
      let n = 0;
      while (s[i] === " ") {
        n++;
        i++;
      }
      out += n === 1 ? " " : `<text:s text:c="${n}"/>`;
    } else {
      out += esc(s[i]);
      i++;
    }
  }
  return out;
}

const SPAN = { b: "Sb", i: "Si", c: "Sc", accent: "Sa" };

function runsToXml(runs, preserve) {
  return runs
    .map((run) => {
      const body = preserve ? escPreserve(run.text) : esc(run.text);
      const style = SPAN[run.style];
      return style ? `<text:span text:style-name="${style}">${body}</text:span>` : body;
    })
    .join("");
}

// Every style is emitted fully expanded: an automatic style cannot inherit from
// another automatic style, so a `style:parent-style-name` here would silently
// fall back to Writer's default face.
function paraStyle(name, spec) {
  const {
    font = SANS,
    size = 12,
    color = INK,
    weight = "normal",
    lineHeight,
    para = "",
    text = "",
  } = spec;
  const height = lineHeight ? ` style:line-height-at-least="${lineHeight.toFixed(2)}pt"` : "";
  return (
    `<style:style style:name="${name}" style:family="paragraph">` +
    `<style:paragraph-properties fo:margin="0pt"${height} ${para}/>` +
    `<style:text-properties style:font-name="${font}" fo:font-family="&apos;${font}&apos;"` +
    ` fo:font-size="${size}pt" fo:color="${color}" fo:font-weight="${weight}"${text}/>` +
    `</style:style>`
  );
}

// The body styles, one family per line type and one set per font size, plus the
// indent variants the bullet wrapping asks for.
function bodyStyles() {
  const out = [];
  for (const fs of FONT_SIZES) {
    const lh = LINE_FACTOR * fs;
    const specs = {
      Ptext: { font: SANS, size: fs, lineHeight: lh },
      Pcode: { font: MONO, size: fs, lineHeight: lh },
      Pthead: { font: MONO, size: fs, color: ACCENT, weight: "bold", lineHeight: lh },
      Ptrule: { font: MONO, size: fs, color: RULE, lineHeight: lh },
      Pquote: {
        font: SANS,
        size: fs,
        color: MUTED,
        lineHeight: lh,
        para: `fo:margin-left="${(fs * 1.2).toFixed(1)}pt" fo:border-left="1.5pt solid ${ACCENT}" fo:padding-left="${(fs * 0.6).toFixed(1)}pt"`,
        text: ' fo:font-style="italic"',
      },
      Psub: { font: SANS, size: fs + 1, color: ACCENT, weight: "bold", lineHeight: lh },
      Pblank: { font: SANS, size: Math.max(4, Math.round(fs * 0.55)), lineHeight: lh * 0.55 },
    };

    for (const [name, spec] of Object.entries(specs)) {
      out.push(paraStyle(`${name}${fs}`, spec));
      if (name === "Ptext" || name === "Pcode") {
        for (let n = 1; n <= 14; n++) {
          out.push(
            paraStyle(`${name}${fs}I${n}`, {
              ...spec,
              para: `fo:margin-left="${(n * fs * TEXT_ADVANCE).toFixed(1)}pt"`,
            }),
          );
        }
      }
    }
  }
  return out.join("");
}

const HEAD_STYLES = [
  ["Pkicker", ""],
  ["PkickerBreak", ' fo:break-before="page"'],
]
  .map(([name, brk]) =>
    paraStyle(name, {
      font: SANS,
      size: 9,
      color: ACCENT,
      weight: "bold",
      para: brk,
      text: ' fo:letter-spacing="0.06em"',
    }),
  )
  .concat(
    [
      ["Ptitle", ""],
      ["PtitleBreak", ' fo:break-before="page"'],
    ].map(([name, brk]) =>
      paraStyle(name, {
        font: SANS,
        size: 21,
        weight: "bold",
        para:
          `fo:margin-top="1pt" fo:padding-bottom="6pt" fo:border-bottom="0.8pt solid ${RULE}"` +
          ` fo:margin-bottom="12pt"${brk}`,
      }),
    ),
  )
  .join("");

function buildFodt(pages) {
  const styles =
    `<style:style style:name="Sb" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>` +
    `<style:style style:name="Si" style:family="text"><style:text-properties fo:font-style="italic"/></style:style>` +
    `<style:style style:name="Sc" style:family="text"><style:text-properties style:font-name="${MONO}" fo:font-family="&apos;${MONO}&apos;" fo:color="${ACCENT}"/></style:style>` +
    `<style:style style:name="Sa" style:family="text"><style:text-properties fo:color="${ACCENT}" fo:font-weight="bold"/></style:style>` +
    HEAD_STYLES +
    [
      ["Pdivider", ""],
      ["PdividerBreak", ' fo:break-before="page"'],
    ]
      .map(([name, brk]) =>
        paraStyle(name, {
          font: SANS,
          size: 30,
          weight: "bold",
          para: `fo:margin-top="128pt" fo:text-align="center"${brk}`,
        }),
      )
      .join("") +
    paraStyle("Pdividerlead", {
      font: SANS,
      size: 14,
      color: MUTED,
      para: 'fo:margin-top="14pt" fo:margin-left="96pt" fo:margin-right="96pt" fo:text-align="center"',
    }) +
    paraStyle("PcoverTitle", {
      font: SANS,
      size: 38,
      weight: "bold",
      para: 'fo:margin-top="80pt" fo:text-align="center"',
    }) +
    paraStyle("PcoverRule", {
      font: SANS,
      size: 6,
      para: `fo:margin-top="16pt" fo:margin-left="270pt" fo:margin-right="270pt" fo:border-bottom="2pt solid ${ACCENT}"`,
    }) +
    paraStyle("Pcover", {
      font: SANS,
      size: 15,
      color: MUTED,
      para: 'fo:margin-top="12pt" fo:text-align="center"',
    }) +
    paraStyle("Pfooter", {
      font: SANS,
      size: 8,
      color: MUTED,
      para: 'fo:text-align="right"',
    }) +
    bodyStyles();

  const body = pages
    .map((page, index) => {
      const first = index === 0;

      if (page.divider) {
        const lead = page.blocks
          .map((b) => stripInline(b.text))
          .map((t) => `<text:p text:style-name="Pdividerlead">${esc(t)}</text:p>`)
          .join("");
        return (
          `<text:p text:style-name="${first ? "Pdivider" : "PdividerBreak"}">${esc(
            stripInline(page.title),
          )}</text:p>` +
          `<text:p text:style-name="PcoverRule"><text:s/></text:p>` +
          lead
        );
      }

      if (page.cover) {
        const sub = page.blocks
          .filter((b) => b.kind === "heading" || b.kind === "para")
          .map((b) => stripInline(b.text))
          .map((t) => `<text:p text:style-name="Pcover">${esc(t)}</text:p>`)
          .join("");
        return (
          `<text:p text:style-name="PcoverTitle">${esc(stripInline(page.title))}</text:p>` +
          `<text:p text:style-name="PcoverRule"><text:s/></text:p>` +
          sub
        );
      }

      const showKicker =
        page.kicker && stripInline(page.kicker) !== stripInline(page.title);
      const head = showKicker
        ? `<text:p text:style-name="${first ? "Pkicker" : "PkickerBreak"}">${esc(
            page.kicker.toUpperCase(),
          )}</text:p><text:p text:style-name="Ptitle">${esc(stripInline(page.title))}</text:p>`
        : `<text:p text:style-name="${first ? "Ptitle" : "PtitleBreak"}">${esc(
            stripInline(page.title),
          )}</text:p>`;

      const lines = page.lines
        .map((line) => {
          const preserve = ["code", "thead", "trule"].includes(line.type);
          const base = {
            text: "Ptext",
            code: "Pcode",
            thead: "Pthead",
            trule: "Ptrule",
            quote: "Pquote",
            sub: "Psub",
            blank: "Pblank",
          }[line.type];
          const indentable = base === "Ptext" || base === "Pcode";
          const indent = indentable && line.indent ? `I${Math.min(14, Math.round(line.indent))}` : "";
          const xml = runsToXml(line.runs, preserve);
          return `<text:p text:style-name="${base}${page.fs}${indent}">${
            xml || "<text:s/>"
          }</text:p>`;
        })
        .join("");

      return head + lines;
    })
    .join("");

  return `<?xml version="1.0" encoding="UTF-8"?>
<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.text">
<office:font-face-decls>
<style:font-face style:name="${SANS}" svg:font-family="&apos;${SANS}&apos;" style:font-family-generic="swiss" style:font-pitch="variable"/>
<style:font-face style:name="${MONO}" svg:font-family="&apos;${MONO}&apos;" style:font-family-generic="modern" style:font-pitch="fixed"/>
</office:font-face-decls>
<office:automatic-styles>
${styles}
<style:page-layout style:name="Slide">
<style:page-layout-properties fo:page-width="${PAGE_W}pt" fo:page-height="${PAGE_H}pt" style:print-orientation="landscape" fo:margin-left="${MARGIN_X}pt" fo:margin-right="${MARGIN_X}pt" fo:margin-top="${MARGIN_TOP}pt" fo:margin-bottom="${MARGIN_BOTTOM}pt" fo:background-color="${PAPER}"/>
<style:footer-style><style:header-footer-properties fo:min-height="10pt" fo:margin-top="8pt"/></style:footer-style>
</style:page-layout>
</office:automatic-styles>
<office:master-styles>
<style:master-page style:name="Standard" style:page-layout-name="Slide">
<style:footer><text:p text:style-name="Pfooter">Bitcoin Staking &amp; Esbee DAO  ·  <text:page-number text:select-page="current">1</text:page-number></text:p></style:footer>
</style:master-page>
</office:master-styles>
<office:body><office:text>
${body}
</office:text></office:body>
</office:document>`;
}

// -- Run ----------------------------------------------------------------------

const md = readFileSync(SRC, "utf8");
const pages = paginate(toSlides(parseBlocks(md)));

const work = join(tmpdir(), `slides-${process.pid}`);
mkdirSync(work, { recursive: true });
const fodt = join(work, basename(OUT).replace(/\.pdf$/, ".fodt"));
writeFileSync(fodt, buildFodt(pages), "utf8");

execFileSync(
  "libreoffice",
  ["--headless", `-env:UserInstallation=file://${join(work, "lo")}`, "--convert-to", "pdf", "--outdir", work, fodt],
  { stdio: "inherit" },
);

const produced = fodt.replace(/\.fodt$/, ".pdf");
mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, readFileSync(produced));

console.log(`${pages.length} slides -> ${OUT}`);
