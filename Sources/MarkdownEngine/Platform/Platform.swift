//
//  Platform.swift
//  MarkdownEngine
//
//  The AppKit and UIKit types the shared code names, under one name each.
//

/// What moved the caret or changed the text, for choices that differ between typing and pointing.
enum EditorInputKind {
    case key, click, drag, other
}

#if canImport(AppKit)
import AppKit

public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
public typealias PlatformImage = NSImage
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformEdgeInsets = NSEdgeInsets
public typealias PlatformTextView = NSTextView
public typealias PlatformAppearance = NSAppearance

extension PlatformColor {
    public static var platformLabel: PlatformColor { .labelColor }
    public static var platformSecondaryLabel: PlatformColor { .secondaryLabelColor }
    public static var platformTertiaryLabel: PlatformColor { .tertiaryLabelColor }
    public static var platformLink: PlatformColor { .linkColor }
    public static var platformTextBackground: PlatformColor { .textBackgroundColor }

    /// sRGB red, green, blue and alpha; nil when the colour has no RGB form.
    var rgbaComponents: (CGFloat, CGFloat, CGFloat, CGFloat)? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
}

extension PlatformAppearance {
    /// A string that tells appearances apart, for cache keys.
    var cacheKey: String { name.rawValue }
}

extension PlatformFont {
    /// The font with this PostScript name; AppKit resolves the system font's private names itself.
    static func named(_ name: String, size: CGFloat) -> PlatformFont? {
        if let font = PlatformFont(name: name, size: size) { return font }
        // Fork: the bold system font's private name (`.SFNS-Bold`) doesn't resolve by name.
        return name.hasPrefix(".") && name.contains("Bold") ? PlatformFont.systemFont(ofSize: size, weight: .bold) : nil
    }
}

extension NSTextView {
    /// The text storage, optional on both platforms (UIKit's isn't).
    var optionalTextStorage: NSTextStorage? { textStorage }

    /// The selection: AppKit's `selectedRange()`, UIKit's `selectedRange`.
    var currentSelectedRange: NSRange { selectedRange() }

    /// The selected ranges: AppKit's `selectedRanges`, UIKit's one range.
    var currentSelectedRanges: [NSRange] { selectedRanges.map(\.rangeValue) }

    /// Fork: whether the caret and selection reveal markdown syntax: while editable (a table cell's editor, only
    /// while it has the keyboard).
    var revealsSyntax: Bool { isEditable && ((self as? NativeTextView).map { !$0.hidesSyntaxUnlessFocused || $0.hasEditingFocus } ?? true) }

    /// The text container, optional on both platforms (UIKit's isn't).
    var optionalTextContainer: NSTextContainer? { textContainer }

    /// The character index nearest a point in the view's coordinates.
    func characterIndex(atViewPoint point: CGPoint) -> Int { characterIndexForInsertion(at: point) }

    /// A rect in the view's coordinates as a menu anchor: screen coordinates.
    func menuAnchorRect(forViewRect rect: CGRect) -> CGRect {
        window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }

    /// A character range's first line rect in screen coordinates, to anchor a menu.
    func anchorRect(forCharacterRange range: NSRange) -> CGRect {
        firstRect(forCharacterRange: range, actualRange: nil)
    }
}

/// Makes `context` the current drawing context, as text layout draws (flipped). Pair with `popGraphicsContext()`.
func pushGraphicsContext(_ context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
}

func popGraphicsContext() { NSGraphicsContext.restoreGraphicsState() }

/// Device pixels per point for `textView`'s screen.
func displayScale(of textView: PlatformTextView?) -> CGFloat {
    textView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
}

/// The appearance `textView` draws in.
func currentAppearance(of textView: PlatformTextView?) -> PlatformAppearance {
    textView?.effectiveAppearance ?? NSApp.effectiveAppearance
}

/// The event being handled, from AppKit's current event.
func currentInputKind(of textView: PlatformTextView) -> EditorInputKind {
    switch NSApp.currentEvent?.type {
    case .keyDown: .key
    case .leftMouseDown, .leftMouseUp: .click
    case .leftMouseDragged, .periodic: .drag
    default: .other
    }
}

/// An image drawn by `draw` in top-left-origin coordinates.
func drawnImage(size: CGSize, draw: @escaping () -> Void) -> PlatformImage {
    PlatformImage(size: size, flipped: true) { _ in
        draw()
        return true
    }
}

extension PlatformBezierPath {
    /// Fills by the even-odd rule, so overlapping rects cut holes.
    func useEvenOddFill() { windingRule = .evenOdd }
}

extension PlatformColor {
    /// The colour as it draws under `appearance`, fixed to that appearance.
    func resolved(under appearance: PlatformAppearance) -> PlatformColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }
}
#else
import UIKit

public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
public typealias PlatformImage = UIImage
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformEdgeInsets = UIEdgeInsets
public typealias PlatformTextView = UITextView
public typealias PlatformAppearance = UITraitCollection

extension PlatformColor {
    public static var platformLabel: PlatformColor { .label }
    public static var platformSecondaryLabel: PlatformColor { .secondaryLabel }
    public static var platformTertiaryLabel: PlatformColor { .tertiaryLabel }
    public static var platformLink: PlatformColor { .link }
    public static var platformTextBackground: PlatformColor { .systemBackground }

    /// AppKit's `alphaComponent`.
    var alphaComponent: CGFloat { cgColor.alpha }

    /// sRGB red, green, blue and alpha; nil when the colour has no RGB form.
    var rgbaComponents: (CGFloat, CGFloat, CGFloat, CGFloat)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        return getRed(&r, green: &g, blue: &b, alpha: &a) ? (r, g, b, a) : nil
    }
}

extension UITraitCollection {
    /// AppKit's `performAsCurrentDrawingAppearance(_:)`.
    func performAsCurrentDrawingAppearance(_ body: () -> Void) { performAsCurrent(body) }

    /// A string that tells appearances apart, for cache keys.
    var cacheKey: String { "\(userInterfaceStyle.rawValue)|\(displayScale)" }
}

extension NSAttributedString.Key {
    /// AppKit's spelling-state attribute; inert on iOS.
    static let spellingState = NSAttributedString.Key("NSSpellingState")
}

extension NSValue {
    /// AppKit's `NSValue(rect:)`.
    convenience init(rect: CGRect) { self.init(cgRect: rect) }
    /// AppKit's `rectValue`.
    var rectValue: CGRect { cgRectValue }
}

extension UIFont {
    /// AppKit's failable `NSFont(descriptor:size:)`, so a descriptor that may be nil reads the same on both.
    convenience init?(descriptor: UIFontDescriptor?, size: CGFloat) {
        guard let descriptor else { return nil }
        self.init(descriptor: descriptor, size: size)
    }
}

extension UIFontDescriptor.SymbolicTraits {
    static let bold = traitBold
    static let italic = traitItalic
    static let monoSpace = traitMonoSpace
}

extension UITextView {
    /// AppKit's `string`.
    var string: String {
        get { text ?? "" }
        set { text = newValue }
    }

    /// AppKit's `setSelectedRange(_:)`.
    func setSelectedRange(_ range: NSRange) { selectedRange = range }

    /// The text storage, optional on both platforms (UIKit's isn't).
    var optionalTextStorage: NSTextStorage? { textStorage }

    /// Replaces `range` as an undoable edit the delegate hears of.
    func replaceCharacters(in range: NSRange, with string: String) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        let selection = selectedRange
        textStorage.replaceCharacters(in: range, with: string)
        // Fork: move the selection as AppKit does: past an edit before it, to the end of one it overlaps.
        let length = (string as NSString).length
        if selection.location >= NSMaxRange(range) {
            selectedRange = NSRange(location: selection.location + length - range.length, length: selection.length)
        } else if NSMaxRange(selection) > range.location {
            selectedRange = NSRange(location: range.location + length, length: 0)
        }
        didChangeText()
    }

    /// AppKit's `shouldChangeText(in:replacementString:)`: asks the delegate, then registers
    /// the undo of a direct `textStorage` edit, which UIKit doesn't track.
    func shouldChangeText(in range: NSRange, replacementString string: String?) -> Bool {
        if delegate?.textView?(self, shouldChangeTextIn: range, replacementText: string ?? "") == false {
            return false
        }
        guard let string, NSMaxRange(range) <= textStorage.length else { return true }
        let previous = textStorage.attributedSubstring(from: range)
        let changed = NSRange(location: range.location, length: (string as NSString).length)
        undoManager?.registerUndo(withTarget: self) { textView in
            guard textView.shouldChangeText(in: changed, replacementString: previous.string) else { return }
            textView.textStorage.replaceCharacters(in: changed, with: previous)
            textView.didChangeText()
        }
        return true
    }

    /// AppKit's `didChangeText()`: tells the delegate the text changed.
    func didChangeText() { delegate?.textViewDidChange?(self) }

    /// AppKit's `breakUndoCoalescing()`; UIKit groups undo per run-loop turn already.
    func breakUndoCoalescing() {}

    /// The selection: AppKit's `selectedRange()`, UIKit's `selectedRange`.
    var currentSelectedRange: NSRange { selectedRange }

    /// The selected ranges: AppKit's `selectedRanges`, UIKit's one range.
    var currentSelectedRanges: [NSRange] { [selectedRange] }

    /// Fork: whether the caret and selection reveal markdown syntax: while editable and
    /// the keyboard is up, since the caret isn't shown once the text view resigns.
    var revealsSyntax: Bool { isEditable && isFirstResponder }

    /// AppKit's `insertionPointColor`; UIKit tints the caret and selection together.
    var insertionPointColor: UIColor? {
        get { tintColor }
        set { tintColor = newValue }
    }

    /// AppKit's `hasMarkedText()`.
    func hasMarkedText() -> Bool { markedTextRange != nil }

    /// The text container, optional on both platforms (UIKit's isn't).
    var optionalTextContainer: NSTextContainer? { textContainer }

    /// The character index nearest a point in the view's coordinates.
    func characterIndex(atViewPoint point: CGPoint) -> Int {
        guard let position = closestPosition(to: point) else { return 0 }
        return offset(from: beginningOfDocument, to: position)
    }

    /// A rect in the view's coordinates as a menu anchor: window coordinates.
    func menuAnchorRect(forViewRect rect: CGRect) -> CGRect { convert(rect, to: nil) }

    /// A character range's first line rect in window coordinates, to anchor a menu.
    func anchorRect(forCharacterRange range: NSRange) -> CGRect {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return .zero }
        return convert(firstRect(for: textRange), to: nil)
    }

    /// AppKit's `textContainerOrigin`.
    var textContainerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }

    /// AppKit's `visibleRect`, in the text view's coordinates.
    var visibleRect: CGRect { CGRect(origin: contentOffset, size: bounds.size) }
}

extension NSTextContainer {
    /// AppKit's `containerSize`.
    var containerSize: CGSize { size }

    private static let textViews = NSMapTable<NSTextContainer, UITextView>.weakToWeakObjects()

    /// AppKit's `textView`; a `NativeTextView` registers itself.
    var textView: UITextView? {
        get { Self.textViews.object(forKey: self) }
        set { Self.textViews.setObject(newValue, forKey: self) }
    }
}
/// Makes `context` the current drawing context. Pair with `popGraphicsContext()`.
func pushGraphicsContext(_ context: CGContext) { UIGraphicsPushContext(context) }

func popGraphicsContext() { UIGraphicsPopContext() }

/// Device pixels per point for `textView`'s screen.
func displayScale(of textView: PlatformTextView?) -> CGFloat {
    guard let scale = textView?.traitCollection.displayScale, scale > 0 else { return 2 }
    return scale
}
/// The appearance `textView` draws in.
func currentAppearance(of textView: PlatformTextView?) -> PlatformAppearance {
    textView?.traitCollection ?? UITraitCollection.current
}

/// The input being handled, as the iOS editor last recorded it.
func currentInputKind(of textView: PlatformTextView) -> EditorInputKind {
    (textView as? NativeTextView)?.inputKind ?? .other
}

/// An image drawn by `draw` in top-left-origin coordinates.
func drawnImage(size: CGSize, draw: () -> Void) -> PlatformImage {
    UIGraphicsImageRenderer(size: size).image { _ in draw() }
}

extension UIColor {
    /// The colour as it draws under `appearance`, fixed to that appearance.
    func resolved(under appearance: UITraitCollection) -> UIColor { resolvedColor(with: appearance) }
}

extension UIBezierPath {
    /// AppKit's `line(to:)`.
    func line(to point: CGPoint) { addLine(to: point) }
    /// AppKit's `appendRect(_:)`.
    func appendRect(_ rect: CGRect) { append(UIBezierPath(rect: rect)) }
    /// Fills by the even-odd rule, so overlapping rects cut holes.
    func useEvenOddFill() { usesEvenOddFillRule = true }
}

extension UIImage {
    /// AppKit's SF Symbol initializer.
    convenience init?(systemSymbolName name: String, accessibilityDescription: String?) {
        self.init(systemName: name)
    }

    /// AppKit's `withSymbolConfiguration(_:)`.
    func withSymbolConfiguration(_ configuration: SymbolConfiguration) -> UIImage? {
        withConfiguration(configuration)
    }
}

extension UIEdgeInsets {
    /// AppKit's `textContainerInset.width`: the inset on each side, horizontally.
    var width: CGFloat { (left + right) / 2 }
}
extension UIFont {
    /// The font with this PostScript name. UIKit returns a serif fallback for the system
    /// font's private names (`.SFUI-Regular`), so those map to the system font.
    static func named(_ name: String, size: CGFloat) -> UIFont? {
        guard name.hasPrefix(".") else { return UIFont(name: name, size: size) }
        let system = UIFont.systemFont(ofSize: size)
        guard let face = name.split(separator: "-").last?.lowercased(), face != "regular" else { return system }
        let weights: [String: UIFont.Weight] = ["bold": .bold, "semibold": .semibold, "medium": .medium, "light": .light]
        return weights[face].map { UIFont.systemFont(ofSize: size, weight: $0) } ?? system
    }
}
#endif
