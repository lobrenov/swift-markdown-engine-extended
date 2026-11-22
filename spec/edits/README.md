# Edits

Recommended: how an editor or tool changes this markdown without disturbing what an edit doesn't touch.

## Principles

- **Never re-serialise.** Change the bytes the edit is about; everything else stays as it was read, including spacing, markers, indentation and line endings (`\n` or `\r\n`).
- **A task box** changes one character, the marker between `[` and `]`. Toggle: an `open` marker becomes `x`, a `done` or `cancelled` one a space, an `icon` one doesn't change (`state` in `../data/task-markers.json`).
- **A callout's type** replaces only the text between `[!` and `]`; the fold marker and title stay. Folding is a view's state; an app that saves it changes only the fold marker (`+`, `-`).
- **A table** edit rewrites only the table's lines: each column padded to its widest cell (at least 3), each alignment marker (`:--`, `:-:`, `--:`) and the table's indent kept, `|` in a cell written `\|`, a line break `<br>`.
- **Lists**: Return continues the item's markers (quotes, indent, bullet or the next number, an open box for a task); Return on an empty item removes its marker. Tab nests an item under its previous sibling with a tab, taking its children with it; Shift-Tab undoes one level.
- **A tag rename or delete** changes only the tag's own bytes. Every inline tag whose path equals `from` or starts with `from/` is matched, comparing the non-empty segments ignoring case (`a//b` is `a/b`); a sibling that merely starts with the same letters (`#homework` for `home`) isn't. A rename replaces the matched prefix of the path with `to`; the rest of the path keeps its spelling, its empty segments dropped. A delete removes the tag with its `#`, its trailing `/`s, and one adjacent whitespace character, the one before it, else the one after it, never a line break; a line left empty stays as an empty line. An `*` or `_` emphasis or strong span left holding only the tag (and whitespace) is removed with its markers, and the whitespace rule applies to the span; a span with other content keeps its markers. Text where no tag is read (code, HTML, URLs, link text, `[[…]]`, an escaped `\#`, a heading's marker) stays, and the text is unchanged when nothing matches.
- **A link rewrite** (a renamed target) changes only the target, keeping the folder path as written, `.md`, `#heading`, `#^block` and `|alias`. Links in code stay.

## Cases

`<area>.json`: `{ "description", "cases": [...] }`. Each case:

| Key | Holds |
|---|---|
| `name` | What it shows. |
| `command` | `type`, `indent`, `outdent`, `task.toggle`, `task.set`, `callout.setType`, `table.insertRow`, `table.deleteRow`, `table.moveRow`, `table.insertColumn`, `table.deleteColumn`, `table.moveColumn`, `table.setAlignment`, `table.setCell`, `link.rewrite`, `tag.rename`, `tag.delete`. |
| `args` | The command's arguments: `text` (typed, `\n` is Return); `line` (0-based, the task, callout title or table's first line); `marker`; `type`; `row` (0 is the header), `column`, `from`, `to`, `text`, `alignment` (`none`, `left`, `center`, `right`); a link rewrite's and a tag rename's `from` and `to`; a tag delete's `from`. |
| `before`, `after` | The text, with `‸` at the caret or `«…»` around the selection. A case without either applies at the end. |
| `skip` | Optional: `{ "<reader>": "<reason>" }`. |
