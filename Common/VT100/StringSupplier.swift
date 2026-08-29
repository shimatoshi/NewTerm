//
//  StringSupplier.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import Foundation
import SwiftTerm
import SwiftUI

fileprivate extension View {
	static func + (lhs: Self, rhs: some View) -> AnyView {
		AnyView(ViewBuilder.buildBlock(lhs, AnyView(rhs)))
	}
}

// Reports the width SwiftUI actually laid the text out at, as measured by the layout system
// itself. CoreText metrics (CTLineGetTypographicBounds) don't reliably predict how wide a Text
// view ends up on screen once font fallback/cascading kicks in for CJK glyphs, which is why a
// scale factor derived from CoreText alone left a stray gap next to every wide character. Measuring
// the real, rendered width sidesteps that mismatch entirely.
fileprivate struct RunWidthKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}

fileprivate struct ScaledCellText: View {
	let run: String
	let font: UIFont?
	let foreground: UIColor?
	let background: UIColor?
	let underline: Bool
	let strikethrough: Bool
	let targetWidth: CGFloat

	@State private var measuredWidth: CGFloat?

	var body: some View {
		let scaleX: CGFloat = {
			guard let measuredWidth = measuredWidth, measuredWidth > 0 else { return 1 }
			return targetWidth / measuredWidth
		}()

		Text(run)
			.foregroundColor(Color(foreground ?? .white))
			.font(Font(font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
			.underline(underline)
			.strikethrough(strikethrough)
			.tracking(0)
			.allowsTightening(false)
			.lineLimit(1)
			.fixedSize()
			.background(
				GeometryReader { geometry in
					Color.clear
						.preference(key: RunWidthKey.self, value: geometry.size.width)
				}
			)
			.onPreferenceChange(RunWidthKey.self) { width in
				if width > 0 && width != measuredWidth {
					measuredWidth = width
				}
			}
			.scaleEffect(x: scaleX, y: 1, anchor: .leading)
			.frame(width: targetWidth, alignment: .leading)
			.background(Color(background ?? .black))
	}
}

open class StringSupplier {

	open var terminal: Terminal!
	open var colorMap: ColorMap!
	open var fontMetrics: FontMetrics!
	open var cursorVisible = true

	public init() {}

	public func attributedString(forScrollInvariantRow row: Int) -> AnyView {
		guard let terminal = terminal else {
			fatalError()
		}

		guard let line = terminal.getScrollInvariantLine(row: row) else {
			return AnyView(EmptyView())
		}

		let cursorPosition = terminal.getCursorLocation()
		let scrollbackRows = terminal.getTopVisibleRow()

		var lastAttribute = Attribute.empty
		var views = [AnyView]()
		var buffer = ""
		var j = 0
		while j < terminal.cols {
			let data = line[j]
			let isCursor = cursorVisible && row - scrollbackRows == cursorPosition.y && j == cursorPosition.x

			if isCursor || lastAttribute != data.attribute {
				// Finish up the last run by appending it to the attributed string, then reset for the
				// next run.
				views.append(text(buffer, attribute: lastAttribute))
				lastAttribute = data.attribute
				buffer.removeAll()
			}

			let character = data.getCharacter()
			buffer.append(character == "\0" ? " " : character)

			if isCursor {
				// We may need to insert a space for the cursor to show up.
				if buffer.isEmpty {
					buffer.append(" ")
				}

				views.append(text(buffer, attribute: lastAttribute, isCursor: true))
				buffer.removeAll()
			}

			// Full-width (e.g. CJK) characters reserve a second, empty placeholder cell in the
			// terminal buffer to hold their extra column. That placeholder carries no glyph of its
			// own — rendering it as a separate character adds a stray blank cell after every wide
			// character, which is what produced the "gap between every character" spacing bug.
			j += data.width == 2 ? 2 : 1
		}

		// Append the final run
		views.append(text(buffer, attribute: lastAttribute))

		return AnyView(HStack(alignment: .firstTextBaseline, spacing: 0) {
			views.reduce(AnyView(EmptyView()), { $0 + $1 })
		})
	}

	private func text(_ run: String, attribute: Attribute, isCursor: Bool = false) -> AnyView {
		var fgColor = attribute.fg
		var bgColor = attribute.bg

		if attribute.style.contains(.inverse) {
			swap(&bgColor, &fgColor)
			if fgColor == .defaultColor {
				fgColor = .defaultInvertedColor
			}
			if bgColor == .defaultColor {
				bgColor = .defaultInvertedColor
			}
		}

		let foreground = colorMap?.color(for: fgColor,
																		 isForeground: true,
																		 isBold: attribute.style.contains(.bold),
																		 isCursor: isCursor)
		let background = colorMap?.color(for: bgColor,
																		 isForeground: false,
																		 isCursor: isCursor)

		let font: UIFont?
		if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
			font = attribute.style.contains(.italic) ? fontMetrics?.boldItalicFont : fontMetrics?.boldFont
		} else if attribute.style.contains(.dim) {
			font = attribute.style.contains(.italic) ? fontMetrics?.lightItalicFont : fontMetrics?.lightFont
		} else {
			font = attribute.style.contains(.italic) ? fontMetrics?.italicFont : fontMetrics?.regularFont
		}

		let width = CGFloat(run.unicodeScalars.reduce(0, { $0 + UnicodeUtil.columnWidth(rune: $1) })) * (fontMetrics?.width ?? 0)

		return AnyView(
			ScaledCellText(run: run,
										 font: font,
										 foreground: foreground,
										 background: background,
										 underline: attribute.style.contains(.underline),
										 strikethrough: attribute.style.contains(.crossedOut),
										 targetWidth: width)
		)
	}

}
