# Host API vocabulary

The words an editor and its host use for the same things, so a feature is described once whatever the language. The Swift column is this package's API.

| Concept | Shape | Swift |
|---|---|---|
| Triggers | `slash`, `link`, `embed`, `tag` → a request with the trigger, the query and an anchor rect, answered by `insert(text)` or `dismiss()` | `onSlashCommandChange(SlashCommandState?)`, `SlashCommandProxy.insert(_:selecting:)` / `dismiss()` |
| Picker keys | ↑, ↓, confirm, confirm-and-open, cancel for whichever picker is open | `onInlinePreviewKey(InlinePreviewKey) -> Bool` |
| Menu requests | Each carries what was hit and the edits the editor can apply; the host draws the menu and calls back | `onTaskMarkerMenu(TaskMarkerMenuRequest)` (set a marker), `onCalloutMenu(CalloutMenuRequest)` (set a type), `onImageEmbed(ImageEmbedRequest)`, `onRightClickMenu(RightClickMenuRequest)` |
| Services | Resolve a link or an attachment, load an image, save a pasted image, highlight code, render math | `MarkdownEditorServices`, `onPasteImage` |
| Events | A link opened (target, heading, block), a tag opened, the text changed | `onLinkClick(String)`, `onTagClick(String)`, `onTextMutation(MarkdownTextMutation)` |
| Edits | The commands in `edits/` | Applied by the editor when a menu or key asks |
