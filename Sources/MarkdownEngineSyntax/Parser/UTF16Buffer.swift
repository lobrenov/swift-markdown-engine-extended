//
//  UTF16Buffer.swift
//  MarkdownEngine
//
//  Fork: text the parsers read one UTF-16 unit at a time, from an array
//  instead of through `NSString.character(at:)`.
//

import Foundation

/// Fork: UTF-16 text read one unit at a time.
package protocol UTF16Text {
    var length: Int { get }
    func character(at index: Int) -> unichar
    func substring(with range: NSRange) -> String
}

extension NSString: UTF16Text {}

/// Fork: a string's UTF-16 units, copied once.
struct UTF16Buffer: UTF16Text {
    let string: NSString
    private let units: [unichar]

    init(_ string: NSString) {
        self.string = string
        let length = string.length
        units = [unichar](unsafeUninitializedCapacity: length) { buffer, count in
            if length > 0 { string.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length)) }
            count = length
        }
    }

    var length: Int { units.count }
    func character(at index: Int) -> unichar { units[index] }
    func substring(with range: NSRange) -> String { string.substring(with: range) }
    func rangeOfComposedCharacterSequence(at index: Int) -> NSRange { string.rangeOfComposedCharacterSequence(at: index) }
}
