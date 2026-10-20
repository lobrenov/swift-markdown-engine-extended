//
//  EmbedSyntax.swift
//  MarkdownEngineSyntax
//
//  Fork: what makes an embed an image (`spec/data/image-embeds.json`).
//

import Foundation

public enum EmbedSyntax {
    /// The extensions (lowercase) that make an embed's target an image, compared ignoring case.
    public static let imageExtensions: [String] = [
        "avif", "bmp", "gif", "heic", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp",
    ]
}
