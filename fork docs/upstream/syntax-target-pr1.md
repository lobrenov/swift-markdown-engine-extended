Step 1 of 4 for #208: moving the grammar into a Foundation-only `MarkdownEngineSyntax` target. Part of #208.

## Change

The declarations move unchanged into new files in the `MarkdownEngine` target. Targets, access levels and public API are unchanged.

- `InlineSyntax` and `BlockSyntax` move from `Extensions/MarkdownExtension.swift` to `Extensions/ExtensionSyntax.swift`.
- `DirectiveUnit`, `DirectiveValue`, `DirectiveParameter` and `DirectiveSyntax` move from `Directives/MarkdownDirective.swift` to `Directives/DirectiveSyntax.swift`.
- `NSAttributedString.Key.wikiLinkID` and `.taskCheckbox` move from `Parser/MarkdownToken.swift` to `Styling/MarkdownTokenAttributes.swift`, and `MarkdownToken.swift` drops `import AppKit`.

As a result, every file #208 proposes to move into the new target now imports Foundation only: `Parser/`, the two new syntax files, `DirectiveArguments`, `DirectiveRegistry`, `DirectiveScanner` and `PerfTrace`. `ExtensionRegistry` stays in `MarkdownExtension.swift` for now, because it still takes `any MarkdownExtension`; step 2 builds it from syntax values.

## Tests

macOS 27.2, Xcode 27.1, Swift 6.4.

- `swift build` passes with no new warnings.
- `swift test --no-parallel` runs 615 tests in 80 suites with 1 failure: `MarkdownHTMLRendererTests.swift:89`, where `www.example.com` doesn't autolink. The same test fails the same way on unchanged `main` (f762ab7).
- `swift package diagnose-api-breaking-changes main --products MarkdownEngine` reports no breaking changes.
- The `MarkdownEngineDemo` scheme builds.

CHANGELOG entry added under `[Unreleased]`.

## The series

1. This PR: the syntax types in their own files.
2. Build `ExtensionRegistry` and `DirectiveRegistry` from syntax values, keeping the protocol-based initialisers as extensions. Fingerprints stay the same.
3. Add the target and move the files. The moves get a rename-only commit, so #192's changes carry across whichever lands first (see the issue thread).
4. Move the parser-only test suites to `MarkdownEngineSyntaxTests` and add a test that fails if the target imports AppKit, SwiftUI or UIKit.

@luca-chen198, following CONTRIBUTING, this is step 1 as code so you can judge the approach before the larger steps. I'm happy to reshape the series or rename the target.
