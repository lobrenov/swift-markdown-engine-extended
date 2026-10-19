//
//  NativeTextView+ImageSourceButton.swift
//  MarkdownEngine
//
//  Fork: with `imageEmbed.sourceButton` set, hovering a drawn image
//  shows a `</>` button at its top right; a click shows the image's `![[ ]]`
//  source (``SlashCommandProxy/revealImageEmbed(at:)``).
//

#if os(macOS)
import AppKit

extension NativeTextView {

    /// From mouse moves: shows the button on the image under the pointer, or hides it.
    func updateImageSourceButton(for event: NSEvent) {
        guard let colors = configuration.imageEmbed.sourceButton,
              let hit = imageEmbedHit(atViewPoint: convert(event.locationInWindow, from: nil)) else {
            return hideImageSourceButton()
        }
        let button = imageSourceButton ?? {
            let button = ImageSourceButton()
            addSubview(button)
            imageSourceButton = button
            return button
        }()
        button.colors = colors
        button.embedLocation = hit.range.location
        button.onClick = { [weak self] location in
            self?.hideImageSourceButton()
            (self?.delegate as? NativeTextViewCoordinator)?.revealImageEmbed(at: location)
        }
        button.frame = CGRect(x: hit.rect.maxX - 8 - ImageSourceButton.size.width, y: hit.rect.minY + 8,
                              width: ImageSourceButton.size.width, height: ImageSourceButton.size.height)
        button.isHidden = false
    }

    func hideImageSourceButton() {
        imageSourceButton?.isHidden = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideImageSourceButton()
    }
}

/// The `</>` button over a hovered image. "Show markdown" is its tooltip.
final class ImageSourceButton: NSView {
    static let size = CGSize(width: 28, height: 24)

    var colors = ImageEmbedStyle.SourceButtonColors(fill: .windowBackgroundColor, hoverFill: .selectedControlColor,
                                                    ring: .separatorColor, tint: .labelColor, hoverTint: .controlAccentColor) {
        didSet { updateColors() }
    }
    var embedLocation = 0
    var onClick: (Int) -> Void = { _ in }
    private let symbol = NSImageView()
    private var isHovered = false { didSet { updateColors() } }

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        toolTip = "Show markdown"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show markdown")
        symbol.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        symbol.frame = bounds
        symbol.autoresizingMask = [.width, .height]
        addSubview(symbol)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(embedLocation) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func accessibilityPerformPress() -> Bool {
        onClick(embedLocation)
        return true
    }

    private func updateColors() {
        layer?.backgroundColor = (isHovered ? colors.hoverFill : colors.fill).cgColor
        layer?.borderColor = colors.ring.cgColor
        symbol.contentTintColor = isHovered ? colors.hoverTint : colors.tint
    }
}
#endif
