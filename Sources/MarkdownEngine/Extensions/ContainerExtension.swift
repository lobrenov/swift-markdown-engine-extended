//
//  ContainerExtension.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 15.07.26.
//
//  `:::` fenced container as the first block extension. Not registered by
//  default — the core engine parses pure markdown; embedders opt in via:
//
//      configuration.extensions = [ContainerExtension()]
//
//  Syntax:
//
//      ::: note
//      Body text with **inline** markdown.
//      :::
//
//  The fence lines hide while the caret is outside the block and reveal
//  muted while editing (mirroring code fences); the body keeps full inline
//  styling plus the container background. An unclosed container runs to the end
//  of the document (unlike an unclosed ``` fence, which stays literal text
//  until its closing fence exists).
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation

public struct ContainerExtension: MarkdownExtension {

    /// Well-known id.
    public static let identifier = "container"

    /// Background tint applied to the container block.
    public var backgroundColor: PlatformColor

    /// The default resolves per appearance: `withAlphaComponent` on a dynamic
    /// system color FREEZES it (same gotcha the table renderer documents), so
    /// the tint is rebuilt inside a dynamic provider and keeps tracking
    /// light/dark mode.
    public static var defaultBackground: PlatformColor {
        #if os(macOS)
        PlatformColor(name: nil) { appearance in
            var resolved = PlatformColor.systemBlue
            appearance.performAsCurrentDrawingAppearance {
                resolved = PlatformColor.systemBlue.usingColorSpace(.sRGB) ?? .systemBlue
            }
            return resolved.withAlphaComponent(0.12)
        }
        #else
        PlatformColor { traits in PlatformColor.systemBlue.resolvedColor(with: traits).withAlphaComponent(0.12) }
        #endif
    }

    public init(backgroundColor: PlatformColor = ContainerExtension.defaultBackground) {
        self.backgroundColor = backgroundColor
    }

    public var id: String { Self.identifier }

    public var block: BlockSyntax? {
        BlockSyntax(fence: ":::")
    }

    public func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: backgroundColor]
    }

    public func html(childrenHTML: String) -> String {
        "<blockquote>\(childrenHTML)</blockquote>"
    }
}
