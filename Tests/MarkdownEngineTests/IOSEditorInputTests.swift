//
//  IOSEditorInputTests.swift
//  MarkdownEngineTests
//
//  Typing, taps and presses on the iOS editor go through the shared input path.
//

#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import MarkdownEngine

@MainActor
final class IOSEditorHarness {
    private final class Box {
        var text: String
        var markerRequests: [TaskMarkerMenuRequest] = []
        var calloutRequests: [CalloutMenuRequest] = []
        var toggles: [Character] = []
        var links: [String] = []
        init(_ text: String) { self.text = text }
    }

    private let box: Box
    var text: String { box.text }
    var markerRequests: [TaskMarkerMenuRequest] { box.markerRequests }
    var calloutRequests: [CalloutMenuRequest] { box.calloutRequests }
    var toggles: [Character] { box.toggles }
    var links: [String] { box.links }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let textView: NativeTextView
    let proxy = SlashCommandProxy()

    init(_ text: String, configure: (inout MarkdownEditorConfiguration) -> Void = { _ in }) throws {
        let box = Box(text)
        self.box = box
        var configuration = MarkdownEditorConfiguration.default
        configuration.callouts = CalloutStyle(
            tint: { _ in .systemTeal }, drawIcon: { _, _, _ in },
            titleColor: .label, bodyColor: .label, foldColor: .secondaryLabel, targetColor: .systemBlue,
            fillOpacity: 0.09, ringOpacity: 0.24
        )
        configure(&configuration)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let editor = NativeTextViewWrapper(
            text: binding,
            configuration: configuration,
            fontName: UIFont.systemFont(ofSize: 17).fontName,
            fontSize: 17,
            documentId: "doc",
            onLinkClick: { box.links.append($0) },
            slashCommandProxy: proxy,
            onTaskMarkerMenu: { box.markerRequests.append($0) },
            onCalloutMenu: { box.calloutRequests.append($0) },
            onTaskCheckboxToggle: { box.toggles.append($0) }
        )
        window.rootViewController = UIHostingController(rootView: editor)
        window.makeKeyAndVisible()
        func find(_ view: UIView) -> NativeTextView? {
            if let textView = view as? NativeTextView { return textView }
            for subview in view.subviews { if let textView = find(subview) { return textView } }
            return nil
        }
        Self.settle(window)
        textView = try #require(find(window))
        textView.becomeFirstResponder()
    }

    static func settle(_ window: UIWindow) {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Lets queued main-queue work run (the binding is published asynchronously), then lays out.
    func settle() async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(30))
            window.layoutIfNeeded()
        }
    }

    /// Types `typed` at the caret as the keyboard does: the delegate may take the keystroke itself.
    func type(_ typed: String) async {
        let range = textView.selectedRange
        if textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: typed) ?? true {
            textView.insertText(typed)
        }
        await settle()
    }

    /// Puts the caret after `marker`'s first occurrence and types `typed`.
    func type(_ typed: String, after marker: String) async {
        let location = NSMaxRange((textView.string as NSString).range(of: marker))
        textView.selectedRange = NSRange(location: location, length: 0)
        await type(typed)
    }

    /// The view point at the middle of `text`'s first occurrence.
    func point(of text: String) -> CGPoint? {
        let range = (textView.string as NSString).range(of: text)
        guard range.location != NSNotFound, let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return nil }
        let rect = textView.firstRect(for: textRange)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// The view point of the first task box, found by probing along its line.
    func boxPoint() -> CGPoint? {
        guard let storage = textView.optionalTextStorage, let bridge = textView.layoutBridge else { return nil }
        var boxRange: NSRange?
        storage.enumerateAttribute(.taskCheckbox, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { boxRange = range; stop.pointee = true }
        }
        guard let boxRange else { return nil }
        let line = bridge.boundingRect(forCharacterRange: boxRange, in: textView.textContainer)
        let y = line.midY + textView.textContainerOrigin.y
        return stride(from: CGFloat(0), to: 120, by: 1)
            .map { CGPoint(x: $0, y: y) }
            .first { textView.taskCheckboxHit(atViewPoint: $0) != nil }
    }
}

private struct Titles: WikiLinkResolver {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        displayName == "Target" ? WikiLinkResolution(id: displayName, exists: true) : nil
    }
}

private struct TealImage: EmbeddedImageProvider {
    func image(for request: EmbeddedImageRequest) -> PlatformImage? {
        request.name == "front.png" ? UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        } : nil
    }
    func fingerprint() -> AnyHashable { 1 }
}

@MainActor
@Suite(.serialized)
struct IOSEditorInputTests {
    @Test func anImageOnThePasteboardPastesAsAnEmbedOnItsOwnLine() async throws {
        let editor = try IOSEditorHarness("Shots:")
        var pasted = 0
        editor.textView.onPasteImage = { _ in pasted += 1; return "![[Pasted image.png]]" }
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        editor.textView.selectedRange = NSRange(location: 6, length: 0)
        #expect(editor.textView.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil))
        editor.textView.paste(nil)
        await editor.settle()
        #expect(pasted == 1)
        #expect(editor.text == "Shots:\n![[Pasted image.png]]")
        UIPasteboard.general.items = []
    }

    @Test func aPressAndHoldOnAnImageShowsTheEmbeddersMenu() async throws {
        let editor = try IOSEditorHarness("Shots:\n\n![[front.png]]\n\nAfter") { configuration in
            configuration.services = MarkdownEditorServices(images: TealImage())
            configuration.imageEmbed.revealsSourceAtCaret = false
        }
        var requests: [ImageEmbedRequest] = []
        editor.textView.imageEmbedMenu = { requests.append($0); return UIMenu(children: []) }
        let embed = (editor.textView.string as NSString).range(of: "![[front.png]]")
        let rect = try #require(editor.textView.imageEmbedRect(for: embed))
        #expect(rect.size == CGSize(width: 300, height: 200))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        #expect(editor.textView.takesPress(at: center) && !editor.textView.takesPress(at: CGPoint(x: center.x, y: rect.maxY + 40)))
        #expect(editor.textView.imageEmbedMenu(for: embed) != nil)
        #expect(requests.map(\.name) == ["front.png"])
        requests[0].revealSource()
        #expect(editor.textView.selectedRange == NSRange(location: NSMaxRange(embed), length: 0))
        requests[0].remove("Cut Image")
        await editor.settle()
        #expect(editor.text == "Shots:\n\n\n\nAfter")
    }

    @Test func loadsTheDocument() async throws {
        let editor = try IOSEditorHarness("- [ ] First")
        #expect(editor.textView.string == "- [ ] First")
    }

    @Test func returnContinuesATaskList() async throws {
        let editor = try IOSEditorHarness("- [ ] First")
        await editor.type("\n", after: "First")
        #expect(editor.textView.string == "- [ ] First\n- [ ] ")
        #expect(editor.text == "- [ ] First\n- [ ] ")
        #expect(editor.textView.selectedRange == NSRange(location: 18, length: 0))
    }

    @Test func returnContinuesABulletListAfterTheCaret() async throws {
        let editor = try IOSEditorHarness("- a\n\nAfter")
        await editor.type("\n", after: "- a")
        #expect(editor.textView.string == "- a\n- \n\nAfter")
        #expect(editor.textView.selectedRange == NSRange(location: 6, length: 0))
    }

    @Test func tabIndentsAListItemUnderItsSibling() async throws {
        let editor = try IOSEditorHarness("- a\n- b")
        let caret = NSMaxRange((editor.textView.string as NSString).range(of: "- b")) - 1
        editor.textView.selectedRange = NSRange(location: caret, length: 0)
        await editor.type("\t")
        #expect(editor.textView.string == "- a\n\t- b")
    }

    @Test func shiftTabOutdents() async throws {
        let editor = try IOSEditorHarness("- a\n\t- b")
        editor.textView.selectedRange = NSRange(location: (editor.textView.string as NSString).length, length: 0)
        editor.textView.outdent()
        await editor.settle()
        #expect(editor.textView.string == "- a\n- b")
    }

    @Test func doubleBracketClosesAWikilink() async throws {
        let editor = try IOSEditorHarness("See ")
        await editor.type("[", after: "See ")
        await editor.type("[")
        #expect(editor.textView.string == "See [[]]")
    }

    @Test func aTypedCloserStepsOverTheOneTheEditorAdded() async throws {
        let editor = try IOSEditorHarness("See ")
        await editor.type("(", after: "See ")
        for character in "word)" { await editor.type(String(character)) }
        #expect(editor.textView.string == "See (word)")
        #expect(editor.textView.selectedRange == NSRange(location: 10, length: 0))
    }

    @Test func aFormattingButtonTappedAgainStepsOverItsCloser() async throws {
        let editor = try IOSEditorHarness("See ")
        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        let coordinator = try #require(editor.textView.delegate as? NativeTextViewCoordinator)
        coordinator.didMarkdownBold(nil)
        for character in "word" { await editor.type(String(character)) }
        coordinator.didMarkdownBold(nil)
        #expect(editor.textView.string == "See **word**")
        #expect(editor.textView.selectedRange == NSRange(location: 12, length: 0))
    }

    @Test func aFormattingButtonTappedAgainOnItsEmptyPairRemovesIt() async throws {
        let editor = try IOSEditorHarness("See ")
        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        editor.proxy.apply(.bold)
        #expect(editor.textView.string == "See ****")
        await editor.settle()
        editor.proxy.apply(.bold)
        await editor.settle()
        #expect(editor.textView.string == "See ")
        #expect(editor.textView.selectedRange == NSRange(location: 4, length: 0))
        #expect(editor.textView.autoPairs.isEmpty)
    }

    @Test func oneUndoRevertsAFormattingInsertion() async throws {
        let editor = try IOSEditorHarness("Intro\nLine")
        let coordinator = try #require(editor.textView.delegate as? NativeTextViewCoordinator)
        let actions: [(NativeTextViewCoordinator) -> Void] = [
            { $0.didMarkdownBlockquote(nil) }, { $0.didMarkdownLink(nil) }, { $0.didMarkdownCodeBlock(nil) },
            { $0.didMarkdownHorizontalRule(nil) }, { $0.didMarkdownImage(nil) }
        ]
        for action in actions {
            editor.textView.selectedRange = NSRange(location: 8, length: 0)
            action(coordinator)
            await editor.settle()
            #expect(editor.textView.string != "Intro\nLine")
            editor.textView.undoManager?.undo()
            await editor.settle()
            #expect(editor.textView.string == "Intro\nLine")
        }
    }

    @Test func typingThroughTheProxyPairsAsTheKeyboardDoes() async throws {
        let editor = try IOSEditorHarness("See ")
        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        editor.proxy.type("[")
        editor.proxy.type("[")
        await editor.settle()
        #expect(editor.textView.string == "See [[]]")
        #expect(editor.text == "See [[]]")
        #expect(editor.textView.selectedRange == NSRange(location: 6, length: 0))
    }

    @Test func theTapThatBringsUpTheKeyboardPutsTheCaretWhereItLands() async throws {
        let editor = try IOSEditorHarness("First line\nSecond line\nThird line")
        _ = editor.textView.resignFirstResponder()
        editor.textView.selectedRange = NSRange(location: 33, length: 0)
        await editor.settle()
        let point = try #require(editor.point(of: "Second"))
        editor.textView.handleTap(at: point)
        await editor.settle()
        #expect(editor.textView.isFirstResponder)
        #expect((11...17).contains(editor.textView.selectedRange.location))
    }

    @Test func tappingALinkOpensItUnlessTheCaretIsInIt() async throws {
        let editor = try IOSEditorHarness("Body\n\nSee [[Target]] here") {
            $0.services = MarkdownEditorServices(wikiLinks: Titles())
        }
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        await editor.settle()
        let point = try #require(editor.point(of: "Target"))
        #expect(editor.textView.wikiLinkHit(atViewPoint: point) == "Target")
        editor.textView.handleTap(at: point)
        #expect(editor.links == ["Target"])
        #expect(editor.textView.wikiLinkHit(atViewPoint: CGPoint(x: point.x, y: point.y - 60)) == nil)

        editor.textView.selectedRange = NSRange(location: (editor.textView.string as NSString).range(of: "Target").location + 2, length: 0)
        await editor.settle()
        #expect(editor.textView.wikiLinkHit(atViewPoint: try #require(editor.point(of: "Target"))) == nil)
    }

    @Test func tappingABoxTogglesItAndUndoRestoresIt() async throws {
        let editor = try IOSEditorHarness("- [ ] Task\n\nBody")
        let point = try #require(editor.boxPoint())
        editor.textView.handleTap(at: point)
        await editor.settle()
        #expect(editor.textView.string == "- [x] Task\n\nBody")
        #expect(editor.text == "- [x] Task\n\nBody")
        #expect(editor.toggles == [" "])
        editor.textView.undoManager?.undo()
        await editor.settle()
        #expect(editor.textView.string == "- [ ] Task\n\nBody")
    }

    @Test func pressAndHoldOnABoxRequestsItsMenu() async throws {
        let editor = try IOSEditorHarness("- [ ] Task")
        let point = try #require(editor.boxPoint())
        editor.textView.handlePress(at: point)
        let request = try #require(editor.markerRequests.first)
        #expect(request.marker == " ")
        request.setMarker("/")
        await editor.settle()
        #expect(editor.textView.string == "- [/] Task")
    }

    @Test func pressAndHoldOnACalloutTitleRequestsItsMenu() async throws {
        let editor = try IOSEditorHarness("> [!note] Title\n> Body\n\nAfter")
        await editor.settle()
        let bridge = try #require(editor.textView.layoutBridge)
        let line = bridge.boundingRect(forCharacterRange: (editor.textView.string as NSString).range(of: "Title"), in: editor.textView.textContainer)
        editor.textView.handlePress(at: CGPoint(x: 200, y: line.midY + editor.textView.textContainerOrigin.y))
        let request = try #require(editor.calloutRequests.first)
        #expect(request.type == "note")
        request.setType("tip")
        request.close()
        await editor.settle()
        #expect(editor.textView.string == "> [!tip] Title\n> Body\n\nAfter")
    }

    @Test func theCaretsSyntaxHidesWhenTheKeyboardGoes() async throws {
        let editor = try IOSEditorHarness("## Heading\n\nBody")
        func markerFontSize() -> CGFloat? {
            (editor.textView.optionalTextStorage?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
        }
        editor.textView.selectedRange = NSRange(location: (editor.textView.string as NSString).length, length: 0)
        await editor.settle()
        let hidden = markerFontSize()
        editor.textView.selectedRange = NSRange(location: 5, length: 0)
        await editor.settle()
        #expect(editor.textView.isFirstResponder)
        let revealed = markerFontSize()
        #expect(revealed != hidden)
        _ = editor.textView.resignFirstResponder()
        await editor.settle()
        #expect(markerFontSize() == hidden)
        _ = editor.textView.becomeFirstResponder()
        await editor.settle()
        #expect(markerFontSize() == revealed)
    }
}
#endif
