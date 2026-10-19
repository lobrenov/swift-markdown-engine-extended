# Swift Markdown Engine Extended

A fork of [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine): a TextKit 2 markdown editor for macOS and iOS, extended for Obsidian-style markdown. `README.md` covers its purpose; `FORK.md` lists every difference from upstream; `ARCHITECTURE.md` (upstream's) maps the engine.

- Repo: https://github.com/lobrenov/swift-markdown-engine-extended (public; `origin`). Upstream: `upstream`.
- Apps pin an exact `-live.<n>` tag. The package identity is `swift-markdown-engine-extended`, so this folder keeps that name.

## Commands
- macOS tests: `swift test --no-parallel`.
- iOS tests: `xcodebuild -scheme MarkdownEngine-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:MarkdownEngineTests -only-testing:MarkdownEngineSyntaxTests test`. `TEST_RUNNER_MARKDOWN_ENGINE_RENDER_DIR=<dir>` saves the iOS editor render.
- Build one target: `swift build --target MarkdownEngine` (or `MarkdownEngineSyntax`).

## Branches and tags
- `main` mirrors upstream. Never commit to it.
- `live` is the fork and the default branch. Merge upstream into it; never rebase it.
- Tags: `<upstream version>-live.<n>` on `live` (`0.13.0-live.1`). Never move or delete a tag. Push only `-live` tags, one at a time (`git push origin <tag>`), never `--tags`: upstream's plain version tags stay off `origin`.
- Upstream contributions: topic branches cut from `main`.

## Conventions
- `MarkdownEngineSyntax` is the grammar: Foundation only (`FoundationOnlyTests` checks). What the editor uses from it is `package`; its public types keep their `MarkdownEngine` names through `Sources/MarkdownEngine/SyntaxTypes.swift`, which also re-exports the module. Parser tests that need no editor types go in `Tests/MarkdownEngineSyntaxTests`.
- Nothing app-specific: no app names, paths or data in source, tests or docs. Doc comments say what the embedder does.
- Keep upstream's names, layout and files, so upstream merges apply cleanly. New fork files go beside upstream's.
- Mark each change from upstream `Fork:` in the source (`// Fork:`, `/// Fork:`, `@Suite("Fork — …")`). An upstream file changed only in passing gets `//  Fork: changed from upstream; FORK.md lists the changes.` under its file name. Add or update its numbered entry in `FORK.md`, with its **Conflicts** rule.
- Shared code uses the `Platform/Platform.swift` names (`PlatformColor`, `PlatformTextView`…). AppKit-only code sits behind `#if canImport(AppKit)`; tests that drive the AppKit view are `#if os(macOS)`.
- Tests use Swift Testing (`@Test`, `#expect`). Fork behaviour tests go in `Tests/MarkdownEngineTests/ForkTests.swift` or a file named for the feature.
- swift-tools 5.9; platforms macOS 14 and iOS 26.

## Workflow
### An editor or syntax change
1. Make it on `live` (or a topic branch merged into `live`), with tests. Run macOS and iOS tests.
2. Update `FORK.md` if it's a new difference from upstream.
3. Tag the next `-live.<n>`; push `live` and the tag.

### Taking upstream
1. `git fetch upstream --tags`; `git switch main && git merge --ff-only upstream/main && git push`.
2. `git switch live && git merge <version>`. `rerere` is on and replays earlier resolutions.
3. Resolve the rest by each change's **Conflicts** rule in `FORK.md` (Fork's, Re-apply, Upstream's); note any new rule there, and what the release changed that a fork change overrides.
4. macOS and iOS tests; tag `<version>-live.1`; push.

A single upstream fix between releases: `git cherry-pick -x <sha>` on `live`.

### Contributing upstream
1. `git switch -c fix/<name> main`.
2. Change upstream's code with its tests, per `CONTRIBUTING.md`.
3. Push the branch and open a PR against `nodes-app/swift-markdown-engine:main`.
4. Once a release ships it, the merge into `live` brings it in; remove the `FORK.md` entry it replaces.
