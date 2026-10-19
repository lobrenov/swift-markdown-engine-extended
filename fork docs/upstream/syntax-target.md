# Upstream proposal: a Foundation-only `MarkdownEngineSyntax` target

A draft for `nodes-app/swift-markdown-engine`, written against upstream `main` (after 0.14.0). Upstream's `CONTRIBUTING.md` asks for a large or architectural change to arrive as a draft PR with the design in its description, so the text below works as that description or as an issue that asks first. Everything below the line is the text to post; it describes upstream's code only.

---

## Split the parser into a Foundation-only `MarkdownEngineSyntax` target

### Summary
An app that indexes, searches or links the documents it edits can't reuse the editor's reading of them today: the grammar lives in the AppKit editor target. This proposes moving it (`Parser/` and the syntactic halves of the extension and directive seams) into a new target, `MarkdownEngineSyntax`, that depends on Foundation only. `MarkdownEngine` depends on it, and its public API and behaviour don't change. Would you take this as a series of PRs?

### Why
- **Embedders need the same reading of the text.** An app that indexes, searches, links or exports the documents it edits has to find the same wiki-links, tasks, headings, tables and extension spans the editor draws. Today it either links the whole AppKit editor into a background indexer or re-implements the grammar and drifts from it. A syntax target lets it parse with the editor's own rules, including whichever extensions and directives it registers.
- **The grammar is already platform-free; nothing enforces it.** `Parser/` is about 3,900 lines with the directive scanners, and all but a few files import Foundation alone. The exceptions are `MarkdownToken.swift`, which declares two `NSAttributedString.Key`s (`wikiLinkID`, `taskCheckbox`), and the seam types the parser reads, which live in files that also hold styling (`InlineSyntax`/`BlockSyntax`/`ExtensionRegistry` beside `MarkdownExtension.contentAttributes`; `DirectiveSyntax`/`DirectiveValue`/`DirectiveParameter` beside `DirectiveFontTransform` and `DirectivePresentation`). A target boundary makes "the parser never touches AppKit" a compile error rather than a convention, the way the core's zero-dependency rule already is.
- **Faster, narrower tests.** The parser suites that use no editor types (`BlockParserTests`, `ASTPipelineTests`, `ParseIncrementalEquivalenceTests`, `BacktickCensusTests`, `FenceInteriorIncrementalTests`) would build and run without AppKit or a text view.

### Proposal
1. **New target** `MarkdownEngineSyntax`, Foundation only, no dependencies. `MarkdownEngine` depends on it. No new product at first (see Open questions).
2. **Moves into it, unchanged in behaviour**
   - `Parser/`: `BlockParser`, `InlineParser`, `MarkdownAST` (`DocumentAST`, `BlockNode`, `InlineNode`, `ListItem`), `DocumentParseState`, `MarkdownTokenizer`, `BlockScopedTokenizer`, `BlockLevelTokenizer`, `InlineASTAdapter`, `MarkdownDetection`, and `MarkdownToken` less its two `NSAttributedString.Key`s, which move to `Styling/`.
   - The extension seam's syntax: `InlineSyntax`, `BlockSyntax` and `ExtensionRegistry`.
   - The directive seam's syntax: `DirectiveSyntax`, `DirectiveParameter`, `DirectiveValue`, `DirectiveUnit`, `DirectiveArguments`, `DirectiveDiagnostic`, `DirectiveRegistry`, `DirectiveRegistrySettings`, `DirectiveScanner`.
   - `Diagnostics/PerfTrace`, which the parser and the editor both call (Foundation only).
3. **Registries are built from syntax values.** `ExtensionRegistry` and `DirectiveRegistry` take the syntax each extension or directive declares (`[InlineSyntax]`, `[BlockSyntax]`, `[DirectiveSyntax]` with ids) instead of `any MarkdownExtension` / `any MarkdownDirective`. `MarkdownEngine` keeps today's initialisers as extensions that map its protocols to those values, and the fingerprints are computed as today, so every parse cache keys the same way.
4. **What stays in `MarkdownEngine`**: the `MarkdownExtension` and `MarkdownDirective` protocols (they carry attributes, fonts and glyphs), `DirectiveCompletionScanner` (it asks the directive for `valueCompletions`), and all styling, rendering, input and text-view code.
5. **Access**: the moved types the editor uses become `package` (SwiftPM 5.9, which the manifest already uses), so nothing new becomes public. The public types that move (`InlineSyntax`, `BlockSyntax`, `DirectiveSyntax`, `DirectiveParameter`, `DirectiveValue`, `DirectiveUnit`, `DirectiveArguments`, `DirectiveDiagnostic`, `DirectiveRegistrySettings`) stay reachable as `MarkdownEngine.X` through `public typealias`es, and `MarkdownEngine` re-exports the syntax module (`@_exported import`), so embedders' code compiles unchanged and needs no second import. The re-export is needed: under `MemberImportVisibility`, a typealias alone leaves the type's initialisers and static members out of reach.
6. **Tests**: a `MarkdownEngineSyntaxTests` target takes the parser suites above. The ones that build their registry from `MarkdownExtension`s or `MarkdownDirective`s, render HTML or style (`InlineParserTests`, `DirectiveParserTests`, `DirectiveArgumentTests`, `GoldenCorpusTests`, `InlineSpanDensityTests`, `PrecomputedBlocksTests`, `ListParsingTests`) stay in `MarkdownEngineTests`, importing both modules. One test reads the target's sources and fails on `import AppKit`, `SwiftUI` or `UIKit`.

### Compatibility
- No public API change: same products, same public names through `MarkdownEngine`, same behaviour.
- The corpus fingerprint in `InlineSpanDensityTests` folds `String(describing:)` of the AST, which names the module. Folding it under the old module name (`MarkdownEngineSyntax.` → `MarkdownEngine.`) gives the same `b74649ffbbbe237a`, which shows every tree is unchanged.
- `swift build` and `swift test` stay as they are; `Demo/` needs no change.
- The core keeps zero external dependencies; the new target is internal to the package.

### Performance
Per-keystroke cost stays O(edit); nothing here changes the algorithms or the caches.
- It's a move, not a rewrite. The parsing loops, the claimed-span cursor, `BlockParser`'s buffer memo and `BlockScopedTokenizer`'s per-block memo all stay inside one module, so their calls stay intra-module.
- What crosses the new boundary is the editor's entry points (`DocumentAST.parse`, the tokenizer projection, `MarkdownDetection`), a few calls per keystroke, all of them on non-generic types.
- The registries' fingerprints are computed as today, so every cache hits and misses as it does now.
- Measured on a fork that made this split (optimised build, a 264,000-character document, medians): full parse 13.5–14.8 ms before and 13.3–14.3 ms after; tokenizer projection 0.29 ms before and 0.31 ms after; a scoped restyle of one list item 0.027–0.033 ms before and 0.029–0.030 ms after. The PR that adds the target will carry the same timings from upstream's code.

### Plan (one logical change per PR)
1. Move `MarkdownToken`'s `NSAttributedString.Key`s to `Styling/`, and split the syntax types out of `MarkdownExtension.swift` and `MarkdownDirective.swift` into their own files, still in `MarkdownEngine`. No behaviour change; small diff.
2. Build the registries from syntax values (step 3 above), with the protocol-based initialisers kept as extensions.
3. Add the target, move the files, mark what the editor needs `package`, add the typealiases.
4. Move the parser suites to `MarkdownEngineSyntaxTests` and add the import check.

Each step builds and passes `swift test` on its own, and each gets a `CHANGELOG.md` line under `[Unreleased]`.

### Open questions
- **A public product.** Exposing `MarkdownEngineSyntax` as a library would let embedders parse without the editor, but it makes `DocumentAST` and the node types public API. I'd leave that for a later, separate proposal, once the split has settled, unless you'd rather design the read API now.
- **Naming.** `MarkdownEngineSyntax` follows the `MarkdownEngineCodeBlocks` / `MarkdownEngineLatex` pattern; happy to use another name.

### Not in scope
- No grammar changes and no new constructs.
- No changes to styling, rendering, input or the text view.
