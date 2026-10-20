# Markdown spec

The markdown dialect this package reads: CommonMark and GFM, plus Obsidian's links, embeds, tags, callouts and task markers. Any app or library that reads or writes these files can test itself against it. The Swift package passes it: `Tests/MarkdownEngineSyntaxTests/SpecConformanceTests.swift` runs the grammar cases through `MarkdownFacts` and checks the task markers and tag characters against the parser; `Tests/MarkdownEngineTests/SpecEditConformanceTests.swift` runs the edit cases through the macOS editor and `MarkdownTable`. Callout types are a consumer's table: the parser reads any type.

## Layers

| Layer | Standing | Says | Stops at |
|---|---|---|---|
| **Syntax** (`data/`, `grammar/`) | Normative: a consumer adopts it. | What the text is: which characters make a link, a tag, a task, a callout, and the facts a body yields. | Never what an app does with a fact: no resolution of a link to a file, no task model, no counting. |
| **Edits** (`edits/`) | Recommended: a consumer should follow it. | How to change the text without disturbing what the edit doesn't touch. | An edit's trigger (menu, key, click) is the app's. |
| **Conventions** (`conventions.md`) | Optional: a profile a consumer may adopt. | How frontmatter is written so files stay readable by Obsidian and by each other. Prose and fixtures only: the parser reads no frontmatter. | App models (kinds, statuses, folders, progress) are out of the spec. |

`host-api.md` names the events and requests an editor exchanges with its host, so hosts in different languages use the same words.

## Syntax

### `data/*.json`

Tables a consumer can load or check its own against. Each file has a `description` that states its rule in prose.

| File | Holds |
|---|---|
| `task-markers.json` | Each marker: `marker`, `label`, `strike`, recommended `state` (`open`, `done`, `cancelled`, `icon`). |
| `callout-types.json` | Each type's `id` and `aliases`, the `foldMarkers`, the `unknownType`. |
| `tags.json` | Where a tag starts, its characters, what it needs, where no tag is read. |
| `wiki-links.json` | The delimiters, how the inner text splits, what it can't hold, the characters that break a title. |
| `image-embeds.json` | The extensions that make an embed an image, and the width segment. |

### `grammar/<name>.md` and `<name>.facts.json`

A markdown body (no frontmatter) and the facts it yields. A case passes when a reader's facts equal the file's, key for key. Every top-level key is present (`summary` may be null). In an entry, an optional field is left out when it has no value: an empty `heading`, `block` or `alias` (`[[Note#]]`) is no value. Lines are 0-based; `\n`, `\r\n`, `\r`, U+2028, U+2029 and U+0085 each end a line. Heading and task `text` are raw source; only `summary` drops markup.

```json
{
  "summary": "The first paragraph's plain text, or null.",
  "headings": [{ "line": 0, "level": 1, "text": "Title" }],
  "tasks": [{ "line": 2, "marker": "x", "text": "Buy milk" }],
  "links": [{ "line": 3, "target": "Note", "heading": "Part", "block": "id", "alias": "shown" }],
  "embeds": [{ "line": 4, "target": "front.jpg", "segments": ["300"] }],
  "markdownLinks": [{ "line": 4, "path": "My Note.md", "raw": "My%20Note.md", "angle": false }],
  "tags": [{ "line": 5, "tag": "home/garden" }],
  "callouts": [{ "type": "warning", "fold": "folded", "title": "Careful", "startLine": 6, "endLine": 8 }],
  "tables": [{ "startLine": 10, "endLine": 13, "columns": 2 }]
}
```

- `tasks`: a list item whose marker is followed by `[c]` and a space or tab, `c` from `task-markers.json`; `text` is the rest of its first line, trimmed. A line continuing an item (lazy, or indented after a blank line) belongs to the item, not to the summary.
- `links` and `embeds`: in text order. Inside `[[…]]` and `![[…]]` a backslash is a character of its part (`[[Foo\_bar]]` has the target `Foo\_bar`, and an escape claims nothing), except `\|`, which splits like `|` and drops its backslash (`[[a\|b]]` is target `a`, alias `b`, outside a table too); `\[[A]]` is text. An embed's `segments` are its `|`-separated parts after the target, as written, empty ones included; left out when there's no `|`.
- `markdownLinks`: inline `[text](destination)` links and `![alt](destination)` images, in text order (a link before the links and images in its text), whose destination is a relative path. Read as CommonMark does: the text may hold brackets, images and wiki links, be empty, and cross line endings; a link holds no link (the inner one counts); the destination holds no line ending and, outside `<…>`, no space (`[a](My Note.md)` isn't a link, `[a](<My Note.md>)` is), balances its parens and may hold backslash escapes; an optional title (`"…"`, `'…'`, `(…)`) may follow, on the next line too. `raw` is the destination up to its first `#` or `?` (an escaped one too), as written, escapes included; `path` is `raw` with escapes resolved and percent-decoded (as is when that fails); `angle` tells the destination is written in `<…>`. Left out: a destination with a scheme (`https:`, `mailto:`, `C:`) or starting `//`, one without a path (`#heading`, `?q`), and autolinks. HTML character references in a destination stay as written. Code, HTML blocks and the rest the other facts skip hold none; a table cell, in a quote too, does, and `raw` is as written in the row (`a\|b.md`). A `line` is the source line the link, embed or tag is on, `<br>` in a table cell aside. A link wrapped inside a list item isn't read: each item line is read alone.
  Each use of a reference link or image (`[text][label]`, `[text][]`, `[label]`, and `![alt]…`) whose definition `[label]: destination "title"` exists is an entry too, in the order of the uses, with the definition's destination read as above: `path`, `raw`, `angle`, and a range that every use of that definition shares. Labels match case-insensitively with whitespace collapsed; the first definition of a label wins, whatever its destination; definitions can sit anywhere a paragraph can start, in quotes and list items too, not in code; a definition nobody uses gives none; one that isn't relative (or has no path) gives none for its uses. A use is read as CommonMark reads it: a shortcut `[label]` isn't one when `[…]` follows, and a link holds no link. A definition is not text: it isn't the `summary`, and its parts yield no link, tag or other fact.
- `tags`: in text order, as written, without `#`.
- `callouts`: `type` as written, lowercased; `fold` is `open`, `folded`, or left out; `title` left out when empty. A lazy line after a callout's last quote line continues it.
- `tables`: GFM pipe tables, inside a quote or callout too; `columns` counts the delimiter row's cells. A cell is read as a paragraph of its own, with `\|` as `|`, so `[[Target\|alias]]` in a cell is a link with an alias.
- `tasks` and lists: a list marker with nothing after it (`-`, `*`, `+`, `1.`, `1)`) is an empty list item, so it isn't `summary` text; like CommonMark's, it can't interrupt a paragraph (`Para\n1.` is one paragraph) and `-` under a paragraph is a setext underline.
- `summary`: the first top-level paragraph that isn't link reference definitions only, with emphasis, `~~strikethrough~~`, `==highlight==`, code backticks, markdown link and image syntax (a reference link or image too, when its definition exists; an undefined `[x][nope]` stays as written) and autolink syntax and backslash escapes removed; wiki links, embeds and tags as written; inline HTML tags dropped and entities decoded; each line break a space.
- `headings`: ATX and setext; `text` is as written, without the `#` markers or a closing `#` run.

A case that a reader can't pass yet may carry `"skip": { "<reader>": "<reason>" }`; a skip without a reason is a failure.

## Edits

`edits/README.md` states the splice principles; `edits/<name>.json` holds the cases. See that file for the format.

## Decisions

Where readers of this dialect have disagreed, the spec chooses. Each choice has a fixture.

| Question | Spec | Other reading |
|---|---|---|
| `[/]` | `open`, labelled Doing | Read as a distinct in-progress state; the spec's `state` is the recommended reading, so a reader may refine it. |
| Markers outside the reference set (`[y]`) | Text, not a task | Drawn as a generic task. |
| A tag of digits and `/` (`#2026/10`) | Not a tag | Read as a tag when only digits are excluded. |
| An image embed's segments | A positive number is the width; others are kept as `segments` | `name\|alt\|width` and `WxH` sizes; some editors write an id segment. |
| A reference link whose definition is elsewhere (`[x][ref]`) | A link to the definition's destination | A link only where an inline destination is written. |
| A bare list marker (`1.`) | An empty list item, never summary text | Text, until a space follows. |
| A backslash in `[[…]]` (`[[Foo\_bar]]`) | A character of the link; only `\|` splits | An escape that breaks the link. |
| `[[#Heading]]`, `[[#^block]]` (no target) | A link with an empty `target`: the same file | Not a link. |
| A callout title right after `]` (`> [!info]Title`) | Not a callout: `]` or the fold marker is followed by a space, a tab or the line's end | A callout titled `Title`. |
