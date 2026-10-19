//
//  IOSEditorRenderTests.swift
//  MarkdownEngineTests
//
//  Renders the iOS editor on a phone-sized window and writes a PNG, to compare
//  with the macOS editor by eye. MARKDOWN_ENGINE_RENDER_DIR names the folder (default: temp).
//

#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import MarkdownEngine

@MainActor
struct IOSEditorRenderTests {
    static let sample = """
    # Release checklist

    Get the next version **ready** to ship, see [[Release notes]].

    - [x] Freeze the feature list
    - [/] Update the `README` file
    - [ ] Run the full test suite
    - [!] Fix the failing build

    > [!tip] Keep it short
    > One line per rule. The repo's docs hold the ==rest==.

    1. First
    2. Second
       - nested bullet
    """

    @Test func rendersAPhoneScreen() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.textInsets = TextInsets(horizontal: 16, vertical: 8)
        configuration.callouts = CalloutStyle(
            tint: { _ in .systemTeal },
            drawIcon: { _, rect, tint in
                guard let context = UIGraphicsGetCurrentContext() else { return }
                context.setFillColor(tint.cgColor)
                context.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
            },
            titleColor: .label, bodyColor: .label, foldColor: .secondaryLabel, targetColor: .systemBlue,
            fillOpacity: 0.09, ringOpacity: 0.24
        )
        var text = Self.sample
        let binding = Binding(get: { text }, set: { text = $0 })
        let editor = NativeTextViewWrapper(
            text: binding,
            configuration: configuration,
            fontName: UIFont.systemFont(ofSize: 17).fontName,
            fontSize: 17,
            documentId: "sample"
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: editor)
        window.makeKeyAndVisible()
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        func find(_ view: UIView) -> NativeTextView? {
            if let tv = view as? NativeTextView { return tv }
            for sub in view.subviews { if let tv = find(sub) { return tv } }
            return nil
        }
        let tv = try #require(find(window))
        var fragments = 0
        tv.textLayoutManager?.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            fragments += 1
            if fragments <= 3 { print("DIAG fragment \(type(of: fragment)) \(fragment.layoutFragmentFrame)") }
            return true
        }
        print("DIAG frame=\(tv.frame) len=\(tv.textStorage.length) frags=\(fragments) inset=\(tv.textContainerInset)")
        if tv.textStorage.length > 0 {
            print("DIAG attrs0=\(tv.textStorage.attributes(at: 0, effectiveRange: nil).keys.map(\.rawValue))")
            print("DIAG color0=\(String(describing: tv.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil)))")
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let folder = ProcessInfo.processInfo.environment["MARKDOWN_ENGINE_RENDER_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
        let url = folder.appendingPathComponent("ios-editor.png")
        try #require(image.pngData()).write(to: url)
        print("RENDER=\(url.path)")
        #expect(text == Self.sample)
    }
}
#endif
