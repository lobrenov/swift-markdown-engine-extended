# Swift Markdown Engine Extended

A fork of [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) by Luca Chen and the [Nodes](https://github.com/nodes-app) team: a native TextKit 2 markdown editor, bridged to SwiftUI. The fork extends it for apps that edit Obsidian-style markdown files on the Mac and iPhone, and tracks upstream's releases.

Upstream's [README](https://github.com/nodes-app/swift-markdown-engine/blob/main/README.md) covers the engine itself: configuration, services, theming, extensions and directives. Everything there applies here. This README covers what the fork adds and how it's kept.

## Purpose

- **Obsidian-flavoured editing.** Callouts, wiki-link aliases, alternative task checkboxes, `#tags`, image embeds and live tables, edited in place as Obsidian users expect.
- **iPhone.** The editor runs on iOS 26 as well as macOS 14, sharing parsing, styling, layout and input.
- **Hooks for the embedder.** Slash, link, embed and tag queries; task, callout, image and table menus; and a formatting proxy. The editor reports and the embedding app draws the menus.
- **One owner of the syntax.** The fork's parser is meant to be the single reading of this markdown dialect for the apps that embed it. The grammar is a Foundation-only target, `MarkdownEngineSyntax`, also a product of its own; a shared spec of fixtures is planned.
- **Tracking upstream.** The package, products and module keep upstream's names and layout, so each upstream release merges into the fork.

[FORK.md](FORK.md) lists every difference from upstream, numbered, with the rule for resolving each one when an upstream merge touches it.

## What it adds

| Area | Configuration and API |
|---|---|
| Alternative task checkboxes (`[/]`, `[-]`, `[>]`, `[!]`…) with symbols, tints, strikethrough and a marker menu | `taskCheckbox` (`TaskCheckboxStyle`), `onTaskMarkerMenu` |
| Obsidian callouts (`> [!type]±`), foldable, with a type menu | `callouts` (`CalloutStyle`), `onCalloutMenu` |
| Live tables: a grid of cell editors with row and column grips, drag to move, alignment and a grip menu | `liveTables`, `tableAccent`, `onRightClickMenu`, `MarkdownTable` |
| `#tags` as bubbles, with clicks | `tags` (`TagStyle`), `onTagClick` |
| `[[Target\|alias]]` links | resolves and reports by `Target` |
| Image embeds that stay drawn at the caret, with selection and an image menu | `imageEmbed` (`ImageEmbedStyle`), `onImageEmbed`, `onPasteImage` |
| `/`, `[[`, `![[` and `#` queries for menus the embedder draws | `onSlashCommandChange`, `onInlinePreviewKey`, `SlashCommandProxy` |
| Tab and Shift-Tab on lists, lists inside quotes, bullets by depth, auto-closed pairs | `lists` (`ListStyle`) |
| Inline bubbles for inline code and extensions | `inlineCode.bubble`, `InlineBubble` |
| iOS editor with a keyboard bar, taps and press-and-hold menus | `NativeTextViewWrapper` (UIKit), `keyboardBar` |

## Installation

Pin an exact `-live` tag:

```swift
dependencies: [
    .package(url: "https://github.com/lobrenov/swift-markdown-engine-extended.git", exact: "0.15.0-live.2")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "MarkdownEngine", package: "swift-markdown-engine-extended"),
        ]
    )
]
```

Upstream's `MarkdownEngineCodeBlocks` and `MarkdownEngineLatex` products are still here, unchanged.

## Branches and versions

- `main` mirrors upstream and is never committed to.
- `live` is the fork: upstream plus the changes in [FORK.md](FORK.md). It's the default branch, and upstream releases are merged into it (never rebased).
- Tags are `<upstream version>-live.<n>` on `live`, for example `0.13.0-live.1`. A tag is never moved or deleted.
- Fixes that belong upstream go on topic branches cut from `main`, as pull requests to `nodes-app/swift-markdown-engine`.

## Requirements

- macOS 14 or later; iOS 26 or later
- Swift 5.9 and Xcode 15 or later for macOS; Xcode 26 or later for iOS

## Tests

```bash
swift test --no-parallel
```

```bash
xcodebuild -scheme MarkdownEngine-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:MarkdownEngineTests test
```

[FORK.md](FORK.md) lists known test failures.

## License

Apache License 2.0, as upstream. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Each file changed from upstream carries a `Fork:` notice.
