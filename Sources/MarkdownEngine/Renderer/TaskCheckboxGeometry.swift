//
//  TaskCheckboxGeometry.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 09.07.26.
//
//  Shared geometry for the drawn task-checkbox square. The hidden `[ ] ` chars
//  are collapsed to ~zero advance by the styler, so `drawPosition`/
//  `boundingRect` of the box range sit at the task CONTENT's left edge. The
//  square is right-aligned to that edge with a small gap (Obsidian-style),
//  occupying the `- ` marker slot. Fragment draw and click hit-test both use
//  these functions so their rects can't drift apart.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

enum TaskCheckboxGeometry {

    /// Side length of the square for the given (body) font.
    /// Fork: sized from the line height via `TaskCheckboxStyle.sizeScale`.
    static func size(for font: PlatformFont, style: TaskCheckboxStyle) -> CGFloat {
        let ascent = max(0, font.ascender)
        let descent = max(0, -font.descender)
        let fontHeight = max(1, ceil(ascent + descent))
        return max(1.0, floor(fontHeight * style.sizeScale))
    }

    /// Left edge of the square: right-aligned to the content start x with the style's gap.
    static func boxX(contentX: CGFloat, size: CGFloat, style: TaskCheckboxStyle) -> CGFloat {
        contentX - size - style.contentGap
    }
}
