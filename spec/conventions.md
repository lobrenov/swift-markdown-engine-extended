# Conventions

Optional: a frontmatter profile that keeps files readable by Obsidian and by every app that adopts it. The parser reads no frontmatter, so only this page and its fixtures describe it. What a key means to an app (kinds, statuses, folders, progress) is the app's.

## Frontmatter

- A file may open with YAML between `---` lines. A file without one is still valid.
- **Dates** are `YYYY-MM-DD` strings, never YAML timestamps or times. Read them without a time zone.
- **A link** in a property is a quoted `"[[Title]]"`, so YAML doesn't read it as a list. A list of links is a list of quoted strings.
- **Tags**: `tags:` as a flow list (`[a, b]`), a block list, or a comma-separated string. A leading `#` is dropped; tags match ignoring case; `/` nests (`home/garden` is under `home`); empty segments and a trailing `/` are dropped.
- **Unknown keys** are kept as written: a writer changes only the lines of the keys it sets, and never re-serialises the block.
- A writer adds a key by inserting its line; it never reorders keys or rewrites quoting.

## Filenames

- A file's title is its filename without `.md`.
- A title becomes a filename by dropping or replacing the characters that break a path or a link: `/ \ :` and `* ? " < > |`, and `[ ] # ^ |` (`titleBreakers` in `data/wiki-links.json`). Leading dots are removed.
