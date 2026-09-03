// The shared slide model: markdown in, a list of slides out.
//
// Both builders read the same talk and must agree on where one slide ends and
// the next begins, so the parse and the slide split live here rather than in
// either of them. What each builder does with a slide -- fitting it to a page
// of points, or to a reveal.js section -- is its own business.

// -- Brand ---------------------------------------------------------------------
// From brand/README.md: the comb's ink against warm paper, letters in a warmed
// bitcoin orange.
export const INK = "#1c1a17";
export const PAPER = "#f4f1ea";
export const ACCENT = "#d1620a";
export const MUTED = "#6d6459";
export const RULE = "#d8d0c2";

// -- Markdown -> blocks -------------------------------------------------------

export function parseBlocks(md) {
  const lines = md.split("\n");
  const blocks = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.trim() === "") {
      i++;
      continue;
    }

    if (line.trim() === "---") {
      blocks.push({ kind: "break" });
      i++;
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      blocks.push({
        kind: "heading",
        level: heading[1].length,
        text: heading[2].trim(),
      });
      i++;
      continue;
    }

    if (line.startsWith("```")) {
      const body = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) body.push(lines[i++]);
      i++; // closing fence
      while (body.length && body[body.length - 1].trim() === "") body.pop();
      blocks.push({ kind: "code", lines: body });
      continue;
    }

    if (line.startsWith("|")) {
      const table = [];
      while (i < lines.length && lines[i].startsWith("|")) table.push(lines[i++]);
      blocks.push({ kind: "table", rows: parseTable(table) });
      continue;
    }

    if (/^>\s?/.test(line)) {
      const body = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        body.push(lines[i++].replace(/^>\s?/, ""));
      }
      blocks.push({ kind: "quote", text: body.join(" ").trim() });
      continue;
    }

    const bullet = /^\s*([-*])\s+(.*)$/.exec(line);
    const numbered = /^\s*(\d+)\.\s+(.*)$/.exec(line);
    if (bullet || numbered) {
      const items = [];
      while (i < lines.length) {
        const b = /^\s*([-*])\s+(.*)$/.exec(lines[i]);
        const n = /^\s*(\d+)\.\s+(.*)$/.exec(lines[i]);
        if (b) {
          // A bullet whose text opens with its own glyph keeps that glyph as
          // the marker rather than collecting a second one.
          const text = b[2].trim();
          const own = /^([\u2713\u2717\u2192])\s+(.*)$/.exec(text);
          items.push(
            own ? { marker: own[1], text: own[2] } : { marker: "\u2022", text },
          );
          i++;
        } else if (n) {
          items.push({ marker: `${n[1]}.`, text: n[2].trim() });
          i++;
        } else if (/^\s{2,}\S/.test(lines[i]) && items.length) {
          // continuation of the previous item
          items[items.length - 1].text += " " + lines[i].trim();
          i++;
        } else {
          break;
        }
      }
      blocks.push({ kind: "list", items });
      continue;
    }

    // paragraph: soft-wrapped source lines join into one
    const para = [];
    while (
      i < lines.length &&
      lines[i].trim() !== "" &&
      lines[i].trim() !== "---" &&
      !lines[i].startsWith("|") &&
      !lines[i].startsWith("```") &&
      !/^>\s?/.test(lines[i]) &&
      !/^(#{1,6})\s/.test(lines[i]) &&
      !/^\s*([-*])\s+/.test(lines[i]) &&
      !/^\s*\d+\.\s+/.test(lines[i])
    ) {
      para.push(lines[i++].trim());
    }
    blocks.push({ kind: "para", text: para.join(" ") });
  }

  return blocks;
}

export function parseTable(raw) {
  const split = (row) =>
    row
      .replace(/^\|/, "")
      .replace(/\|\s*$/, "")
      .split("|")
      .map((c) => c.trim());
  const out = raw.map(split).filter((cells) => !cells.every((c) => /^:?-{2,}:?$/.test(c)));
  return out;
}

// -- Blocks -> slides ---------------------------------------------------------
// A `---` opens a slide; an `###` inside one opens another, so that a long
// section does not have to be split by hand.

export function toSlides(blocks) {
  const slides = [];
  let kicker = "";
  let current = null;

  const open = (title, opts = {}) => {
    current = {
      kicker: opts.kicker ?? kicker,
      title,
      blocks: [],
      cover: !!opts.cover,
      section: !!opts.section,
    };
    slides.push(current);
  };

  for (const block of blocks) {
    if (block.kind === "break") {
      current = null;
      continue;
    }

    if (block.kind === "heading" && block.level <= 3) {
      // Everything between the H1 and the first rule belongs to the cover.
      if (current && current.cover && block.level > 1) {
        current.blocks.push(block);
        continue;
      }
      if (block.level === 1) {
        kicker = "";
        open(block.text, { cover: true });
      } else if (block.level === 2) {
        kicker = stripInline(block.text);
        open(block.text, { section: true });
      } else {
        open(block.text);
      }
      continue;
    }

    if (!current) open("");
    current.blocks.push(block);
  }

  // A `##` slide whose body is empty exists only to introduce the `###` slides
  // that follow it; drop it unless it is the cover.
  return slides.filter((s) => s.cover || s.blocks.length > 0);
}

// -- Inline markup ------------------------------------------------------------

export function stripInline(text) {
  return text
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/`(.+?)`/g, "$1")
    .replace(/(^|[\s(])\*(\S(?:.*?\S)?)\*/g, "$1$2")
    .replace(/\[(.+?)\]\(.+?\)/g, "$1");
}

// Split a line into runs so bold / code / italic survive wrapping.
export function inlineRuns(text) {
  const runs = [];
  const re = /\*\*(.+?)\*\*|`(.+?)`|\*(\S(?:.*?\S)?)\*/g;
  let last = 0;
  let m;
  while ((m = re.exec(text))) {
    if (m.index > last) runs.push({ text: text.slice(last, m.index), style: "" });
    if (m[1] !== undefined) runs.push({ text: m[1], style: "b" });
    else if (m[2] !== undefined) runs.push({ text: m[2], style: "c" });
    else runs.push({ text: m[3], style: "i" });
    last = re.lastIndex;
  }
  if (last < text.length) runs.push({ text: text.slice(last), style: "" });
  return runs;
}

// A section-level heading opens a part, and a part opens with a divider: the
// title, a rule, and a sentence of lead-in. What makes it a divider is that its
// body is prose and nothing else -- the moment a `##` slide carries a list, a
// table or a diagram it is a content slide, which is what keeps the agenda and
// the closing slide out of this.
export function isDivider(slide) {
  if (!slide.section || slide.cover) return false;
  if (!slide.blocks.length) return false;
  return slide.blocks.every((b) => b.kind === "para" || b.kind === "quote");
}
