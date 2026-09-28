import SwiftUI
import AppKit
import Combine
import Carbon
import ApplicationServices

// MARK: - Model

enum NoteFontStyle: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "기본"
        case .rounded: return "둥근체"
        case .serif: return "명조체"
        case .monospaced: return "고정폭"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

enum NoteFontWeight: String, CaseIterable, Identifiable {
    case regular
    case bold

    var id: String { rawValue }
    var title: String { self == .regular ? "보통" : "굵게" }
    var value: Font.Weight { self == .regular ? .regular : .bold }
}

struct StickerData: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var richText: AttributedString?
    var richTextRTF: Data?
    var backgroundColor: [Double]?
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var pinned: Bool = false

    enum CodingKeys: String, CodingKey { case id, text, richText, richTextRTF, backgroundColor, x, y, width, height, pinned }

    init(id: UUID, text: String, richText: AttributedString? = nil, richTextRTF: Data? = nil, backgroundColor: [Double]? = nil, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, pinned: Bool = false) {
        self.id = id; self.text = text; self.richText = richText; self.richTextRTF = richTextRTF; self.backgroundColor = backgroundColor; self.x = x; self.y = y
        self.width = width; self.height = height; self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        richText = try c.decodeIfPresent(AttributedString.self, forKey: .richText)
        richTextRTF = try c.decodeIfPresent(Data.self, forKey: .richTextRTF)
        backgroundColor = try c.decodeIfPresent([Double].self, forKey: .backgroundColor)
        x = try c.decode(CGFloat.self, forKey: .x)
        y = try c.decode(CGFloat.self, forKey: .y)
        width = try c.decode(CGFloat.self, forKey: .width)
        height = try c.decode(CGFloat.self, forKey: .height)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

func encodeRichTextRTF(_ text: NSAttributedString) -> Data? {
    try? text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
}

func decodeRichTextRTF(_ data: Data) -> NSAttributedString? {
    try? NSAttributedString(
        data: data,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
    )
}

final class Store {
    static let shared = Store()
    let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickyNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stickers.json")
    }()

    func load() -> [StickerData] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([StickerData].self, from: data) else {
            return []
        }
        return items
    }

    func save(_ items: [StickerData]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Shared app state (drives both dashboard and stickers)

final class AppState: NSObject, ObservableObject {
    private let minimumFontSize: CGFloat = 8
    private let maximumFontSize: CGFloat = 36

    @Published var stickers: [StickerData] = []
    @Published var glassVariant: Int = UserDefaults.standard.integer(forKey: "glassVariant") {
        didSet { UserDefaults.standard.set(glassVariant, forKey: "glassVariant") }
    }
    @Published var regularBgOpacity: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "regularBgOpacity") as? Double
        return CGFloat(v ?? 0.5)
    }() {
        didSet { UserDefaults.standard.set(Double(regularBgOpacity), forKey: "regularBgOpacity") }
    }
    @Published var fontSize: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "fontSize") as? Double
        return CGFloat(v ?? 14)
    }() {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "fontSize") }
    }
    @Published var noteFontStyle: NoteFontStyle = {
        guard let raw = UserDefaults.standard.string(forKey: "noteFontStyle") else { return .rounded }
        return NoteFontStyle(rawValue: raw) ?? .rounded
    }() {
        didSet { UserDefaults.standard.set(noteFontStyle.rawValue, forKey: "noteFontStyle") }
    }
    @Published var noteFontWeight: NoteFontWeight = {
        guard let raw = UserDefaults.standard.string(forKey: "noteFontWeight") else { return .regular }
        return NoteFontWeight(rawValue: raw) ?? .regular
    }() {
        didSet { UserDefaults.standard.set(noteFontWeight.rawValue, forKey: "noteFontWeight") }
    }
    @Published var fontColor: Color = AppState.loadColor("fontColor", default: .white) {
        didSet { AppState.saveColor(fontColor, "fontColor") }
    }
    @Published var bgColor: Color = AppState.loadColor("bgColor", default: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0)) {
        didSet { AppState.saveColor(bgColor, "bgColor") }
    }
    private var colorEditingStickerID: UUID?
    private weak var textColorEditor: NSTextView?
    private weak var rememberedStickerEditor: FixedFontTextView?
    private var textColorRange = NSRange(location: 0, length: 0)

    static func loadColor(_ key: String, default def: Color) -> Color {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 4 else { return def }
        return Color(.sRGB, red: arr[0], green: arr[1], blue: arr[2], opacity: arr[3])
    }
    static func saveColor(_ c: Color, _ key: String) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor.white
        UserDefaults.standard.set(
            [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent)],
            forKey: key
        )
    }

    func backgroundColor(for id: UUID) -> Color {
        guard let components = sticker(id)?.backgroundColor, components.count == 4 else {
            return bgColor
        }
        return Color(
            .sRGB,
            red: components[0],
            green: components[1],
            blue: components[2],
            opacity: components[3]
        )
    }

    func showColorPanel(for id: UUID) {
        colorEditingStickerID = id
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.color = NSColor(backgroundColor(for: id)).usingColorSpace(.sRGB) ?? .white
        panel.setTarget(self)
        panel.setAction(#selector(updateStickerColor(_:)))
        panel.orderFront(nil)
    }

    @objc private func updateStickerColor(_ sender: NSColorPanel) {
        guard let id = colorEditingStickerID,
              var item = sticker(id),
              let color = sender.color.usingColorSpace(.sRGB) else { return }
        item.backgroundColor = [
            Double(color.redComponent),
            Double(color.greenComponent),
            Double(color.blueComponent),
            1
        ]
        upsert(item)
    }

    func showTextColorPanel() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.selectedRange().length > 0 else {
            NSSound.beep()
            return
        }

        textColorEditor = textView
        textColorRange = textView.selectedRange()
        let storage = textView.textStorage
        let selectedColor: NSColor?
        if textColorRange.length > 0,
           textColorRange.location < (storage?.length ?? 0) {
            selectedColor = storage?.attribute(
                .foregroundColor,
                at: textColorRange.location,
                effectiveRange: nil
            ) as? NSColor
        } else {
            selectedColor = textView.typingAttributes[.foregroundColor] as? NSColor
        }

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.color = selectedColor ?? NSColor(fontColor)
        panel.setTarget(self)
        panel.setAction(#selector(updateSelectedTextColor(_:)))
        panel.orderFront(nil)
    }

    @objc private func updateSelectedTextColor(_ sender: NSColorPanel) {
        guard let textView = textColorEditor else { return }
        let color = sender.color.usingColorSpace(.sRGB) ?? sender.color

        guard let storage = textView.textStorage else { return }
        let safeLength = min(textColorRange.length, max(0, storage.length - textColorRange.location))
        let safeRange = NSRange(location: textColorRange.location, length: safeLength)
        guard safeRange.length > 0,
              textView.shouldChangeText(in: safeRange, replacementString: nil) else { return }
        storage.addAttribute(.foregroundColor, value: color, range: safeRange)
        textView.didChangeText()
        var typingAttributes = textView.typingAttributes
        typingAttributes[.foregroundColor] = NSColor(fontColor)
        textView.typingAttributes = typingAttributes
    }

    /// NSColorPanel is shared by the whole app. Once the user leaves it, clear
    /// our background/text action so a later text-selection color refresh
    /// cannot be mistaken for another background-color change.
    func endColorPanelSession(_ panel: NSColorPanel) {
        panel.setTarget(nil)
        panel.setAction(nil)
        colorEditingStickerID = nil
        textColorEditor = nil
        textColorRange = NSRange(location: 0, length: 0)
    }

    func insertTable(rows: Int, columns: Int) {
        guard rows > 0, columns > 0,
              let textView = activeStickerEditor() else {
            NSSound.beep()
            return
        }

        let replacementRange = textView.rangeForUserTextChange
        guard replacementRange.location != NSNotFound else {
            NSSound.beep()
            return
        }

        let source = textView.string as NSString
        let needsLeadingNewline = replacementRange.location > 0 &&
            source.substring(with: NSRange(location: replacementRange.location - 1, length: 1)) != "\n"

        let result = NSMutableAttributedString()
        if needsLeadingNewline {
            result.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes))
        }
        let firstCellOffset = result.length

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let borderColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
        let cellBackground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        let baseFont = textView.typingAttributes[.font] as? NSFont
            ?? textView.font
            ?? NSFont.systemFont(ofSize: fontSize)
        let textColor = textView.typingAttributes[.foregroundColor] as? NSColor
            ?? NSColor(fontColor)

        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: row,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.setBorderColor(borderColor)
                block.backgroundColor = cellBackground
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.paragraphSpacing = 0
                result.append(NSAttributedString(
                    string: " \n",
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: textColor,
                        .paragraphStyle: paragraph
                    ]
                ))
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes))

        let selectionAfter = NSRange(
            location: replacementRange.location + firstCellOffset,
            length: 0
        )
        guard textView.replaceWithUndo(
            range: replacementRange,
            with: result,
            selectedRangeAfter: selectionAfter,
            actionName: "표 삽입"
        ) else {
            NSSound.beep()
            return
        }
        textView.window?.makeFirstResponder(textView)
    }

    func adjustDefaultFontSize(by amount: CGFloat) {
        fontSize = clampedFontSize((fontSize + amount).rounded())
    }

    func adjustEditorFontSize(by amount: CGFloat) {
        changeEditorFontSize(
            actionName: amount > 0 ? "글자 크게" : "글자 작게"
        ) { current in
            self.clampedFontSize((current + amount).rounded())
        }
    }

    func setEditorFontSize(to requestedSize: CGFloat) {
        let targetSize = clampedFontSize(requestedSize.rounded())
        changeEditorFontSize(actionName: "글자 크기") { _ in targetSize }
    }

    func rememberActiveStickerEditor() {
        if let editor = activeStickerEditor() {
            rememberedStickerEditor = editor
        }
    }

    private func changeEditorFontSize(
        actionName: String,
        sizeForCurrent: (CGFloat) -> CGFloat
    ) {
        guard let textView = activeStickerEditor(),
              let storage = textView.textStorage else {
            NSSound.beep()
            return
        }

        let selection = textView.selectedRange()
        if storage.length == 0 {
            var attributes = textView.typingAttributes
            let current = attributes[.font] as? NSFont
                ?? textView.font
                ?? NSFont.systemFont(ofSize: fontSize)
            attributes[.font] = resizedFont(current, to: sizeForCurrent(current.pointSize))
            textView.typingAttributes = attributes
            textView.window?.makeFirstResponder(textView)
            return
        }

        let targetRange = selection.length > 0
            ? selection
            : NSRange(location: 0, length: storage.length)
        guard targetRange.location != NSNotFound,
              NSMaxRange(targetRange) <= storage.length else {
            NSSound.beep()
            return
        }

        let replacement = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: targetRange)
        )
        var resizedRuns: [(NSRange, NSFont)] = []
        replacement.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: replacement.length)
        ) { value, range, _ in
            let current = value as? NSFont
                ?? textView.typingAttributes[.font] as? NSFont
                ?? textView.font
                ?? NSFont.systemFont(ofSize: fontSize)
            resizedRuns.append((range, resizedFont(current, to: sizeForCurrent(current.pointSize))))
        }
        replacement.beginEditing()
        for (range, font) in resizedRuns {
            replacement.addAttribute(.font, value: font, range: range)
        }
        replacement.endEditing()

        guard textView.replaceWithUndo(
            range: targetRange,
            with: replacement,
            selectedRangeAfter: selection,
            actionName: actionName
        ) else {
            NSSound.beep()
            return
        }

        var typingAttributes = textView.typingAttributes
        let nearbyIndex = min(selection.location, max(0, storage.length - 1))
        let adjustedNearbyFont = storage.attribute(
            .font,
            at: nearbyIndex,
            effectiveRange: nil
        ) as? NSFont
        typingAttributes[.font] = adjustedNearbyFont
            ?? resizedFont(
                typingAttributes[.font] as? NSFont
                    ?? textView.font
                    ?? NSFont.systemFont(ofSize: fontSize),
                to: sizeForCurrent(
                    (typingAttributes[.font] as? NSFont)?.pointSize ?? fontSize
                )
            )
        textView.typingAttributes = typingAttributes
        textView.window?.makeFirstResponder(textView)
    }

    private func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(maximumFontSize, max(minimumFontSize, size))
    }

    private func resizedFont(_ font: NSFont, to requestedSize: CGFloat) -> NSFont {
        let size = clampedFontSize(requestedSize.rounded())
        return NSFont(descriptor: font.fontDescriptor, size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    private func activeStickerEditor() -> FixedFontTextView? {
        if let editor = NSApp.keyWindow?.firstResponder as? FixedFontTextView {
            rememberedStickerEditor = editor
            return editor
        }
        if let contentView = NSApp.keyWindow?.contentView,
           let editor = fixedTextEditor(in: contentView) {
            rememberedStickerEditor = editor
            return editor
        }
        if let rememberedStickerEditor,
           rememberedStickerEditor.window?.isVisible == true {
            return rememberedStickerEditor
        }
        return nil
    }

    private func fixedTextEditor(in view: NSView) -> FixedFontTextView? {
        if let editor = view as? FixedFontTextView { return editor }
        for subview in view.subviews {
            if let editor = fixedTextEditor(in: subview) { return editor }
        }
        return nil
    }

    func upsert(_ s: StickerData) {
        if let i = stickers.firstIndex(where: { $0.id == s.id }) {
            stickers[i] = s
        } else {
            stickers.append(s)
        }
        Store.shared.save(stickers)
    }

    func remove(_ id: UUID) {
        stickers.removeAll { $0.id == id }
        Store.shared.save(stickers)
    }

    func sticker(_ id: UUID) -> StickerData? {
        stickers.first { $0.id == id }
    }
}

// MARK: - Liquid Glass background

struct FrostedBackground: View {
    @ObservedObject var state: AppState
    var backgroundColor: Color? = nil
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glass: Glass = (state.glassVariant == 1) ? .clear : .regular
        return ZStack {
            Color.clear.glassEffect(glass, in: shape)
            if state.glassVariant == 0 {
                (backgroundColor ?? state.bgColor)
                    .opacity(state.regularBgOpacity)
                    .clipShape(shape)
            }
        }
    }
}

// MARK: - Sticker view

private func bulletParagraphStyle(from value: Any?) -> NSParagraphStyle {
    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        ?? NSMutableParagraphStyle()
    style.firstLineHeadIndent = 8
    style.headIndent = 28
    style.defaultTabInterval = 28
    style.tabStops = [NSTextTab(textAlignment: .left, location: 28, options: [:])]
    return style
}

private func plainParagraphStyle(from value: Any?) -> NSParagraphStyle {
    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        ?? NSMutableParagraphStyle()
    style.firstLineHeadIndent = 0
    style.headIndent = 0
    style.tabStops = []
    return style
}

final class FixedFontTextView: NSTextView {
    var fixedFont = NSFont.systemFont(ofSize: 14)

    private struct TableCellKey: Hashable {
        let row: Int
        let column: Int
    }

    private struct TableCellContext {
        let table: NSTextTable
        let row: Int
        let column: Int
        let characterIndex: Int
    }

    private var contextTableCell: TableCellContext?

    func normalizeBulletFormatting() {
        guard let storage = textStorage, storage.length >= 2 else { return }
        let source = storage.string as NSString
        var updates: [(bullet: NSRange, separator: NSRange, paragraph: NSRange, bulletFont: NSFont, textFont: NSFont, replaceSpace: Bool)] = []
        var emptyBulletLines: [NSRange] = []
        var searchLocation = 0
        var previousBulletFont: NSFont?
        var previousBulletParagraphEnd: Int?

        while searchLocation < source.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let bulletRange = source.range(of: "•", options: [], range: searchRange)
            guard bulletRange.location != NSNotFound else { break }

            let isLineStart = bulletRange.location == 0 ||
                source.substring(with: NSRange(location: bulletRange.location - 1, length: 1)) == "\n"
            let separatorLocation = NSMaxRange(bulletRange)
            if isLineStart,
               separatorLocation < source.length {
                let separatorRange = NSRange(location: separatorLocation, length: 1)
                let separator = source.substring(with: separatorRange)
                guard separator == " " || separator == "\t" else {
                    searchLocation = NSMaxRange(bulletRange)
                    continue
                }
                guard let textFont = storage.attribute(
                    .font,
                    at: separatorLocation,
                    effectiveRange: nil
                ) as? NSFont else {
                    searchLocation = NSMaxRange(bulletRange)
                    continue
                }
                let paragraphRange = source.lineRange(for: bulletRange)
                let existingBulletFont = storage.attribute(
                    .font,
                    at: bulletRange.location,
                    effectiveRange: nil
                ) as? NSFont
                let bulletFont: NSFont
                if previousBulletParagraphEnd == bulletRange.location,
                   let previousBulletFont {
                    // A continued list must use the exact same bullet glyph as
                    // the line above. Different font families make an equal
                    // point-size bullet look larger and shift horizontally.
                    bulletFont = previousBulletFont
                } else {
                    bulletFont = existingBulletFont ?? textFont
                }
                previousBulletFont = bulletFont
                previousBulletParagraphEnd = NSMaxRange(paragraphRange)
                var contentEnd = NSMaxRange(paragraphRange)
                while contentEnd > separatorLocation + 1 {
                    let trailing = source.substring(with: NSRange(location: contentEnd - 1, length: 1))
                    guard trailing == "\n" || trailing == "\r" else { break }
                    contentEnd -= 1
                }
                let contentRange = NSRange(
                    location: separatorLocation + 1,
                    length: max(0, contentEnd - (separatorLocation + 1))
                )
                if source.substring(with: contentRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    emptyBulletLines.append(paragraphRange)
                    searchLocation = NSMaxRange(bulletRange)
                    continue
                }
                updates.append((
                    bullet: bulletRange,
                    separator: separatorRange,
                    paragraph: paragraphRange,
                    bulletFont: bulletFont,
                    textFont: textFont,
                    replaceSpace: separator == " "
                ))
            }
            searchLocation = NSMaxRange(bulletRange)
        }

        if !emptyBulletLines.isEmpty {
            storage.beginEditing()
            for range in emptyBulletLines.sorted(by: { $0.location > $1.location }) {
                storage.deleteCharacters(in: range)
            }
            storage.endEditing()
            normalizeBulletFormatting()
            return
        }

        guard !updates.isEmpty else { return }
        storage.beginEditing()
        for update in updates {
            if update.replaceSpace {
                storage.replaceCharacters(in: update.separator, with: "\t")
            }
            storage.addAttribute(.font, value: update.bulletFont, range: update.bullet)
            storage.addAttribute(.font, value: update.textFont, range: update.separator)
            let existingStyle = storage.attribute(
                .paragraphStyle,
                at: update.bullet.location,
                effectiveRange: nil
            )
            storage.addAttribute(
                .paragraphStyle,
                value: bulletParagraphStyle(from: existingStyle),
                range: update.paragraph
            )
        }
        storage.endEditing()
    }

    func normalizeTableFormatting() {
        guard let storage = textStorage else { return }
        stylePastedTables(in: storage)
    }

    override func insertNewline(_ sender: Any?) {
        let isSoftBreak = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if !isSoftBreak, handleBulletNewline() { return }
        super.insertNewline(sender)
        resetTypingForNewLine()
    }

    private func handleBulletNewline() -> Bool {
        guard let storage = textStorage else { return false }
        let selection = selectedRange()
        guard selection.length == 0 else { return false }

        let source = string as NSString
        let prefix = source.substring(to: selection.location) as NSString
        let previousNewline = prefix.range(of: "\n", options: .backwards)
        let lineStart = previousNewline.location == NSNotFound
            ? 0
            : NSMaxRange(previousNewline)
        guard selection.location >= lineStart + 2,
              lineStart + 2 <= source.length,
              source.substring(with: NSRange(location: lineStart, length: 1)) == "•" else {
            return false
        }
        let separator = source.substring(with: NSRange(location: lineStart + 1, length: 1))
        guard separator == " " || separator == "\t" else { return false }

        let remainingRange = NSRange(
            location: selection.location,
            length: source.length - selection.location
        )
        let nextNewline = source.range(of: "\n", options: [], range: remainingRange)
        let lineEnd = nextNewline.location == NSNotFound ? source.length : nextNewline.location
        let contentRange = NSRange(
            location: lineStart + 2,
            length: max(0, lineEnd - (lineStart + 2))
        )

        if source.substring(with: contentRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            let ended = replaceWithUndo(
                range: NSRange(location: lineStart, length: lineEnd - lineStart),
                with: NSAttributedString(),
                selectedRangeAfter: NSRange(location: lineStart, length: 0),
                actionName: "글머리 기호 종료"
            )
            if ended { resetTypingForNewLine(removeBulletIndent: true) }
            return ended
        }

        let textFont = defaultNewLineFont()
        let paragraphStyle = bulletParagraphStyle(
            from: storage.attribute(.paragraphStyle, at: lineStart, effectiveRange: nil)
        )
        // Preserve the current line's bullet attributes exactly. Using the
        // editor's default font here made newly continued bullets visibly
        // larger and slightly offset from the existing list.
        var bulletAttributes = storage.attributes(at: lineStart, effectiveRange: nil)
        bulletAttributes[.paragraphStyle] = paragraphStyle
        var tabAttributes = storage.attributes(at: lineStart + 1, effectiveRange: nil)
        tabAttributes[.font] = textFont
        tabAttributes[.paragraphStyle] = paragraphStyle
        var newlineAttributes = typingAttributes
        newlineAttributes[.font] = textFont
        newlineAttributes[.paragraphStyle] = paragraphStyle

        let replacement = NSMutableAttributedString(string: "\n", attributes: newlineAttributes)
        replacement.append(NSAttributedString(string: "•", attributes: bulletAttributes))
        replacement.append(NSAttributedString(string: "\t", attributes: tabAttributes))
        let continued = replaceWithUndo(
            range: selection,
            with: replacement,
            selectedRangeAfter: NSRange(location: selection.location + replacement.length, length: 0),
            actionName: "글머리 기호 계속"
        )
        if continued { resetTypingForNewLine() }
        return continued
    }

    private func resetTypingForNewLine(removeBulletIndent: Bool = false) {
        var attributes = typingAttributes
        attributes[.font] = defaultNewLineFont()
        if removeBulletIndent {
            attributes[.paragraphStyle] = plainParagraphStyle(from: attributes[.paragraphStyle])
        }
        typingAttributes = attributes
    }

    private func defaultNewLineFont() -> NSFont {
        let currentFont = typingAttributes[.font] as? NSFont
            ?? font
            ?? NSFont.systemFont(ofSize: 12)
        let manager = NSFontManager.shared
        var result = NSFont(descriptor: fixedFont.fontDescriptor, size: 12)
            ?? NSFont.systemFont(ofSize: 12)
        let traits = manager.traits(of: currentFont)
        if traits.contains(.boldFontMask) {
            result = manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italicFontMask) {
            result = manager.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    @discardableResult
    func replaceWithUndo(
        range: NSRange,
        with replacement: NSAttributedString,
        selectedRangeAfter: NSRange,
        actionName: String
    ) -> Bool {
        guard let storage = textStorage,
              range.location != NSNotFound,
              NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: nil) else { return false }

        let original = storage.attributedSubstring(from: range)
        let originalSelection = selectedRange()
        storage.replaceCharacters(in: range, with: replacement)
        let safeLocation = min(selectedRangeAfter.location, storage.length)
        let safeLength = min(selectedRangeAfter.length, storage.length - safeLocation)
        setSelectedRange(NSRange(location: safeLocation, length: safeLength))
        didChangeText()

        let insertedRange = NSRange(location: range.location, length: replacement.length)
        undoManager?.registerUndo(withTarget: self) { textView in
            textView.replaceWithUndo(
                range: insertedRange,
                with: original,
                selectedRangeAfter: originalSelection,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        if deleteSelectedEmptyTables() { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if deleteSelectedEmptyTables() { return }
        super.deleteForward(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let characterIndex = characterIndexForInsertion(at: point)
        contextTableCell = tableCellContext(at: characterIndex)

        guard contextTableCell != nil else { return menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        let deleteRowItem = NSMenuItem(
            title: "현재 행 삭제",
            action: #selector(deleteCurrentTableRow(_:)),
            keyEquivalent: ""
        )
        deleteRowItem.target = self
        menu.addItem(deleteRowItem)

        let deleteColumnItem = NSMenuItem(
            title: "현재 열 삭제",
            action: #selector(deleteCurrentTableColumn(_:)),
            keyEquivalent: ""
        )
        deleteColumnItem.target = self
        menu.addItem(deleteColumnItem)
        return menu
    }

    @objc private func deleteCurrentTableRow(_ sender: Any?) {
        guard let contextTableCell else { return }
        rebuildTable(
            for: contextTableCell,
            deletingRow: contextTableCell.row,
            deletingColumn: nil
        )
    }

    @objc private func deleteCurrentTableColumn(_ sender: Any?) {
        guard let contextTableCell else { return }
        rebuildTable(
            for: contextTableCell,
            deletingRow: nil,
            deletingColumn: contextTableCell.column
        )
    }

    private func tableCellContext(at requestedIndex: Int) -> TableCellContext? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(max(0, requestedIndex), storage.length - 1)
        guard let paragraph = storage.attribute(
            .paragraphStyle,
            at: index,
            effectiveRange: nil
        ) as? NSParagraphStyle else { return nil }

        guard let block = paragraph.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last else {
            return nil
        }
        return TableCellContext(
            table: block.table,
            row: block.startingRow,
            column: block.startingColumn,
            characterIndex: index
        )
    }

    private func rebuildTable(
        for context: TableCellContext,
        deletingRow: Int?,
        deletingColumn: Int?
    ) {
        guard let storage = textStorage else { return }
        let tableRange = storage.range(of: context.table, at: context.characterIndex)
        guard tableRange.location != NSNotFound, tableRange.length > 0 else {
            NSSound.beep()
            return
        }

        var cells: [TableCellKey: NSMutableAttributedString] = [:]
        var rowCount = 0
        var columnCount = max(1, context.table.numberOfColumns)

        storage.enumerateAttribute(.paragraphStyle, in: tableRange) { value, range, _ in
            guard let paragraph = value as? NSParagraphStyle,
                  let block = paragraph.textBlocks
                    .compactMap({ $0 as? NSTextTableBlock })
                    .last(where: { $0.table === context.table }) else { return }

            rowCount = max(rowCount, block.startingRow + block.rowSpan)
            columnCount = max(columnCount, block.startingColumn + block.columnSpan)
            let key = TableCellKey(row: block.startingRow, column: block.startingColumn)
            let content = cells[key] ?? NSMutableAttributedString()
            content.append(storage.attributedSubstring(from: range))
            cells[key] = content
        }

        guard rowCount > 0, columnCount > 0 else {
            NSSound.beep()
            return
        }

        let newRowCount = rowCount - (deletingRow == nil ? 0 : 1)
        let newColumnCount = columnCount - (deletingColumn == nil ? 0 : 1)
        if newRowCount <= 0 || newColumnCount <= 0 {
            _ = replaceWithUndo(
                range: tableRange,
                with: NSAttributedString(),
                selectedRangeAfter: NSRange(location: tableRange.location, length: 0),
                actionName: deletingRow == nil ? "열 삭제" : "행 삭제"
            )
            contextTableCell = nil
            return
        }

        let newTable = NSTextTable()
        newTable.numberOfColumns = newColumnCount
        newTable.collapsesBorders = true
        newTable.hidesEmptyCells = false
        let replacement = NSMutableAttributedString()
        let borderColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
        let cellBackground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        let fallbackColor = typingAttributes[.foregroundColor] as? NSColor ?? .textColor

        for oldRow in 0..<rowCount where oldRow != deletingRow {
            let newRow = oldRow - ((deletingRow != nil && oldRow > deletingRow!) ? 1 : 0)
            for oldColumn in 0..<columnCount where oldColumn != deletingColumn {
                let newColumn = oldColumn - ((deletingColumn != nil && oldColumn > deletingColumn!) ? 1 : 0)
                let block = NSTextTableBlock(
                    table: newTable,
                    startingRow: newRow,
                    rowSpan: 1,
                    startingColumn: newColumn,
                    columnSpan: 1
                )
                block.setBorderColor(borderColor)
                block.backgroundColor = cellBackground
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.paragraphSpacing = 0

                let key = TableCellKey(row: oldRow, column: oldColumn)
                let cell = NSMutableAttributedString(
                    attributedString: cells[key] ?? NSAttributedString()
                )
                while cell.length > 0,
                      (cell.string.hasSuffix("\n") || cell.string.hasSuffix("\r")) {
                    cell.deleteCharacters(in: NSRange(location: cell.length - 1, length: 1))
                }
                if cell.length == 0 {
                    cell.append(NSAttributedString(
                        string: " ",
                        attributes: [.font: fixedFont, .foregroundColor: fallbackColor]
                    ))
                }
                cell.append(NSAttributedString(string: "\n", attributes: cell.attributes(at: max(0, cell.length - 1), effectiveRange: nil)))
                cell.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: cell.length)
                )
                replacement.append(cell)
            }
        }

        let actionName = deletingRow == nil ? "열 삭제" : "행 삭제"
        _ = replaceWithUndo(
            range: tableRange,
            with: replacement,
            selectedRangeAfter: NSRange(
                location: min(tableRange.location, storage.length),
                length: 0
            ),
            actionName: actionName
        )
        contextTableCell = nil
    }

    override func paste(_ sender: Any?) {
        let replacedRange = selectedRange()
        let pasteFont = contextualBaseFont(at: replacedRange.location)
        if let table = tableFromPasteboard(baseFont: pasteFont) {
            insertPastedTable(table)
            return
        }

        guard let storage = textStorage else {
            super.paste(sender)
            return
        }

        let oldLength = storage.length
        super.paste(sender)

        let insertedLength = storage.length - (oldLength - replacedRange.length)
        guard insertedLength > 0 else { return }
        let insertedRange = NSRange(
            location: min(replacedRange.location, storage.length),
            length: min(insertedLength, max(0, storage.length - replacedRange.location))
        )
        guard insertedRange.length > 0 else { return }

        normalizeFonts(in: storage, range: insertedRange, baseFont: pasteFont)
        didChangeText()
    }

    private func tableFromPasteboard(baseFont: NSFont) -> NSMutableAttributedString? {
        let pasteboard = NSPasteboard.general

        // Browsers and rendered Markdown normally expose a public.html flavor.
        // Importing that flavor lets AppKit turn <table> cells into native
        // NSTextTableBlocks instead of flattening them into lines of text.
        if let htmlData = pasteboard.data(forType: .html),
           let imported = try? NSMutableAttributedString(
                data: htmlData,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
           ), containsTable(in: imported) {
            removeEmptyTables(from: imported)
            guard containsTable(in: imported) else { return nil }
            stylePastedTables(in: imported)
            normalizeFonts(
                in: imported,
                range: NSRange(location: 0, length: imported.length),
                baseFont: baseFont
            )
            return imported
        }

        // Spreadsheet apps commonly put rows on the clipboard as tab-separated
        // text. Convert that representation into the same native table model.
        if let value = pasteboard.string(forType: .tabularText)
            ?? pasteboard.string(forType: .string),
           let table = tableFromTabSeparatedText(value, baseFont: baseFont) {
            return table
        }
        return nil
    }

    private func containsTable(in text: NSAttributedString) -> Bool {
        guard text.length > 0 else { return false }
        var found = false
        text.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: text.length)
        ) { value, _, stop in
            guard let paragraph = value as? NSParagraphStyle else { return }
            if paragraph.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// HTML copied from browsers often keeps the table structure but leaves
    /// all visible borders in a stylesheet that is not included on the
    /// pasteboard. TextKit still creates NSTextTableBlocks, but without local
    /// styling they look like ordinary lines of text. Apply the same visible
    /// cell treatment used by tables created directly in Stick.
    private func stylePastedTables(in text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        let borderColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
        let cellBackground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        var styledBlocks = Set<ObjectIdentifier>()

        text.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: text.length)
        ) { value, _, _ in
            guard let paragraph = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in paragraph.textBlocks {
                let identifier = ObjectIdentifier(block)
                guard styledBlocks.insert(identifier).inserted else { continue }
                block.table.collapsesBorders = true
                block.table.hidesEmptyCells = false
                block.setBorderColor(borderColor)
                block.backgroundColor = cellBackground
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
            }
        }
    }

    private func tableRanges(
        in text: NSAttributedString,
        intersecting selection: NSRange? = nil
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        let scanRange = selection.map {
            NSIntersectionRange($0, NSRange(location: 0, length: text.length))
        } ?? NSRange(location: 0, length: text.length)
        guard scanRange.length > 0 else { return [] }

        var ranges: [NSRange] = []
        text.enumerateAttribute(.paragraphStyle, in: scanRange) { value, range, _ in
            guard let paragraph = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in paragraph.textBlocks {
                let tableRange = text.range(of: block.table, at: range.location)
                guard tableRange.location != NSNotFound,
                      !ranges.contains(tableRange) else { continue }
                ranges.append(tableRange)
            }
        }
        return ranges
    }

    private func isEmptyTable(_ range: NSRange, in text: NSAttributedString) -> Bool {
        guard NSMaxRange(range) <= text.length else { return false }
        let raw = (text.string as NSString).substring(with: range)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func removeEmptyTables(from text: NSMutableAttributedString) {
        let ranges = tableRanges(in: text)
            .filter { isEmptyTable($0, in: text) }
            .sorted { $0.location > $1.location }
        for range in ranges {
            text.deleteCharacters(in: range)
        }
    }

    private func deleteSelectedEmptyTables() -> Bool {
        guard let storage = textStorage else { return false }
        let selection = selectedRange()
        guard selection.length > 0 else { return false }

        let intersectingTables = tableRanges(in: storage, intersecting: selection)
        let emptyTables = intersectingTables.filter { isEmptyTable($0, in: storage) }
        guard !emptyTables.isEmpty,
              emptyTables.count == intersectingTables.count else { return false }

        var deletionRange = selection
        for tableRange in emptyTables {
            deletionRange = NSUnionRange(deletionRange, tableRange)
        }
        return replaceWithUndo(
            range: deletionRange,
            with: NSAttributedString(),
            selectedRangeAfter: NSRange(location: deletionRange.location, length: 0),
            actionName: "빈 표 삭제"
        )
    }

    private func tableFromTabSeparatedText(
        _ value: String,
        baseFont: NSFont
    ) -> NSMutableAttributedString? {
        var lines = value.components(separatedBy: .newlines)
        while lines.last?.isEmpty == true { lines.removeLast() }
        let rows = lines.map { $0.components(separatedBy: "\t") }
        let columnCount = rows.map(\.count).max() ?? 0
        guard !rows.isEmpty, columnCount > 1 else { return nil }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let result = NSMutableAttributedString()
        let borderColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
        let cellBackground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        let textColor = typingAttributes[.foregroundColor] as? NSColor ?? .textColor

        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setBorderColor(borderColor)
                block.backgroundColor = cellBackground
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                let value = columnIndex < row.count ? row[columnIndex] : ""
                result.append(NSAttributedString(
                    string: value + "\n",
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: textColor,
                        .paragraphStyle: paragraph
                    ]
                ))
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: typingAttributes))
        return result
    }

    private func insertPastedTable(_ table: NSAttributedString) {
        let range = rangeForUserTextChange
        guard replaceWithUndo(
            range: range,
            with: table,
            selectedRangeAfter: NSRange(location: range.location + table.length, length: 0),
            actionName: "표 붙여넣기"
        ) else {
            NSSound.beep()
            return
        }
    }

    private func contextualBaseFont(at location: Int) -> NSFont {
        guard let storage = textStorage, storage.length > 0 else { return fixedFont }
        let source = storage.string as NSString
        var index = min(max(0, location - 1), storage.length - 1)
        while index > 0 {
            let character = source.substring(with: NSRange(location: index, length: 1))
            if !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            index -= 1
        }
        guard let contextFont = storage.attribute(
            .font,
            at: index,
            effectiveRange: nil
        ) as? NSFont else { return fixedFont }
        // Follow only the surrounding point size. The surrounding character
        // may be Korean and therefore use a fallback family such as Apple SD
        // Gothic Neo; adopting that family would make pasted Latin text look
        // different from the rest of the rounded-system-font note.
        let manager = NSFontManager.shared
        var base = NSFont(
            descriptor: fixedFont.fontDescriptor,
            size: contextFont.pointSize
        ) ?? fixedFont
        base = manager.convert(base, toNotHaveTrait: .boldFontMask)
        base = manager.convert(base, toNotHaveTrait: .italicFontMask)
        return base
    }

    private func normalizeFonts(
        in storage: NSMutableAttributedString,
        range: NSRange,
        baseFont: NSFont? = nil
    ) {
        guard range.length > 0 else { return }
        let fontManager = NSFontManager.shared
        let targetBaseFont = baseFont ?? fixedFont
        var normalizedFonts: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, range, _ in
            guard let sourceFont = value as? NSFont else {
                normalizedFonts.append((range, targetBaseFont))
                return
            }

            var normalized = targetBaseFont
            let traits = fontManager.traits(of: sourceFont)
            if traits.contains(.boldFontMask) {
                normalized = fontManager.convert(normalized, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                normalized = fontManager.convert(normalized, toHaveTrait: .italicFontMask)
            }
            normalizedFonts.append((range, normalized))
        }

        storage.beginEditing()
        for (range, font) in normalizedFonts {
            storage.addAttribute(.font, value: font, range: range)
        }
        storage.endEditing()
    }
}

/// An AppKit-backed rich text editor. Keeping the text storage and selection in
/// the same NSTextView makes direct formatting actions (bold, colors,
/// checklists, strikethrough) safe; SwiftUI's TextEditor keeps a separate
/// internal selection model that can become invalid after those mutations.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: Data
    @Binding var displayedFontSize: CGFloat
    let fontSize: CGFloat
    let fontStyle: NoteFontStyle
    let fontWeight: NoteFontWeight
    let fontColor: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = FixedFontTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let initialFont = defaultFont()
        let initialColor = NSColor(fontColor)
        textView.fixedFont = initialFont
        textView.typingAttributes = [
            .font: initialFont,
            .foregroundColor: initialColor
        ]
        context.coordinator.appliedDefaultFont = initialFont
        context.coordinator.appliedDefaultColor = initialColor

        context.coordinator.isApplyingExternalUpdate = true
        textView.textStorage?.setAttributedString(
            decodeRichTextRTF(text) ?? NSAttributedString()
        )
        textView.normalizeBulletFormatting()
        textView.normalizeTableFormatting()
        if let normalized = encodeRichTextRTF(textView.attributedString()),
           normalized != text {
            context.coordinator.lastEmittedData = normalized
            DispatchQueue.main.async {
                context.coordinator.parent.text = normalized
            }
        }
        context.coordinator.isApplyingExternalUpdate = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        if context.coordinator.lastEmittedData != text {
            let desired = decodeRichTextRTF(text) ?? NSAttributedString()
            let current = textView.attributedString()
            if !current.isEqual(to: desired) {
                let oldSelection = textView.selectedRange()
                context.coordinator.isApplyingExternalUpdate = true
                textView.textStorage?.setAttributedString(desired)
                if let fixedTextView = textView as? FixedFontTextView {
                    fixedTextView.normalizeBulletFormatting()
                    fixedTextView.normalizeTableFormatting()
                }
                let length = desired.length
                let location = min(oldSelection.location, length)
                let selectionLength = min(oldSelection.length, length - location)
                textView.setSelectedRange(NSRange(location: location, length: selectionLength))
                context.coordinator.isApplyingExternalUpdate = false
            }
        }

        // NSTextView refreshes typing attributes from the character beside the
        // caret whenever the selection changes. Only replace those defaults
        // when the user actually changes the dashboard font/color settings;
        // doing it on every focus update makes TextKit relayout the caret line.
        let targetFont = defaultFont()
        let targetColor = NSColor(fontColor)
        if let fixedFontTextView = textView as? FixedFontTextView {
            fixedFontTextView.fixedFont = targetFont
        }
        if !context.coordinator.matchesAppliedDefaults(font: targetFont, color: targetColor) {
            var typingAttributes = textView.typingAttributes
            typingAttributes[.font] = targetFont
            typingAttributes[.foregroundColor] = targetColor
            textView.typingAttributes = typingAttributes
            context.coordinator.appliedDefaultFont = targetFont
            context.coordinator.appliedDefaultColor = targetColor
        }
    }

    private func defaultFont() -> NSFont {
        let weight: NSFont.Weight = fontWeight == .bold ? .bold : .regular
        switch fontStyle {
        case .system:
            return NSFont.systemFont(ofSize: fontSize, weight: weight)
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
        case .rounded, .serif:
            let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
            let design: NSFontDescriptor.SystemDesign = fontStyle == .rounded ? .rounded : .serif
            guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
            return NSFont(descriptor: descriptor, size: fontSize) ?? base
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var isApplyingExternalUpdate = false
        var lastEmittedData: Data?
        var appliedDefaultFont: NSFont?
        var appliedDefaultColor: NSColor?

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func matchesAppliedDefaults(font: NSFont, color: NSColor) -> Bool {
            guard let appliedDefaultFont, let appliedDefaultColor else { return false }
            return appliedDefaultFont.isEqual(font) && appliedDefaultColor.isEqual(color)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate,
                  let textView = notification.object as? NSTextView else { return }
            refreshDisplayedFontSize(in: textView)
            guard let updated = encodeRichTextRTF(textView.attributedString()) else { return }
            lastEmittedData = updated
            if updated != parent.text {
                parent.text = updated
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            refreshDisplayedFontSize(in: textView)
        }

        private func refreshDisplayedFontSize(in textView: NSTextView) {
            let selection = textView.selectedRange()
            let size: CGFloat
            if let storage = textView.textStorage, storage.length > 0 {
                let index = min(selection.location, storage.length - 1)
                size = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize
                    ?? (textView.typingAttributes[.font] as? NSFont)?.pointSize
                    ?? parent.fontSize
            } else {
                size = (textView.typingAttributes[.font] as? NSFont)?.pointSize
                    ?? parent.fontSize
            }
            guard abs(parent.displayedFontSize - size) > 0.01 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.displayedFontSize = size
            }
        }
    }
}

struct TableSizePicker: View {
    let onSelect: (Int, Int) -> Void
    @State private var hoveredRows = 2
    @State private var hoveredColumns = 2

    private let rowCount = 8
    private let columnCount = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("표 삽입")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(hoveredColumns) × \(hoveredRows)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(20), spacing: 4),
                    count: columnCount
                ),
                spacing: 4
            ) {
                ForEach(0..<(rowCount * columnCount), id: \.self) { index in
                    let row = index / columnCount
                    let column = index % columnCount
                    let selected = row < hoveredRows && column < hoveredColumns
                    RoundedRectangle(cornerRadius: 2)
                        .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(
                                    selected ? Color.accentColor : Color.secondary.opacity(0.65),
                                    lineWidth: selected ? 1.5 : 1
                                )
                        )
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            guard inside else { return }
                            hoveredRows = row + 1
                            hoveredColumns = column + 1
                        }
                        .onTapGesture {
                            onSelect(row + 1, column + 1)
                        }
                }
            }
        }
        .padding(14)
        .frame(width: 270)
    }
}

struct StickerView: View {
    let id: UUID
    @ObservedObject var state: AppState
    let onClose: () -> Void
    let onDrag: () -> Void
    let onTogglePin: () -> Void
    @State private var hovering = false
    @State private var displayedFontSize: CGFloat = 12
    @State private var fontSizeInput = "12"
    @State private var showingTablePicker = false
    @FocusState private var fontSizeFieldFocused: Bool

    private var richText: Binding<Data> {
        Binding(
            get: {
                guard let sticker = state.sticker(id) else { return Data() }
                if let stored = sticker.richTextRTF { return stored }
                if let legacy = sticker.richText {
                    return encodeRichTextRTF(NSAttributedString(legacy)) ?? Data()
                }
                var plain = AttributedString(sticker.text)
                plain.font = .system(
                    size: state.fontSize,
                    weight: state.noteFontWeight.value,
                    design: state.noteFontStyle.design
                )
                return encodeRichTextRTF(NSAttributedString(plain)) ?? Data()
            },
            set: { new in
                guard var s = state.sticker(id),
                      let decoded = decodeRichTextRTF(new) else { return }
                s.richTextRTF = new
                s.richText = nil
                s.text = decoded.string
                state.upsert(s)
            }
        )
    }

    private var isPinned: Bool { state.sticker(id)?.pinned ?? false }

    private var tableSizePicker: some View {
        TableSizePicker { rows, columns in
            showingTablePicker = false
            DispatchQueue.main.async {
                state.insertTable(rows: rows, columns: columns)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar — drag handle
            ZStack {
                Color.black.opacity(0.55)
                GeometryReader { geometry in
                    let compact = geometry.size.width < 268
                    HStack(spacing: compact ? 4 : 7) {
                        Button(action: onClose) {
                            Circle()
                                .fill(Color.white.opacity(hovering ? 1 : 0.7))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold, design: .rounded))
                                        .foregroundColor(.black)
                                        .opacity(hovering ? 1 : 0)
                                )
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Button(action: { state.adjustEditorFontSize(by: -1) }) {
                            Text("−")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("글자 1pt 작게 · 선택 없으면 메모 전체")
                        HStack(spacing: 1) {
                            TextField("", text: $fontSizeInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                                .frame(width: 18)
                                .focused($fontSizeFieldFocused)
                                .onSubmit { fontSizeFieldFocused = false }
                            Text("pt")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                        }
                        .frame(width: 34, height: 20)
                        Button(action: { state.adjustEditorFontSize(by: 1) }) {
                            Text("+")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("글자 1pt 크게 · 선택 없으면 메모 전체")

                        if compact {
                            Menu {
                                Button("표 삽입…") {
                                    state.rememberActiveStickerEditor()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        showingTablePicker = true
                                    }
                                }
                                Button("글자 색상") { state.showTextColorPanel() }
                                Button("메모 색상") { state.showColorPanel(for: id) }
                                Button(isPinned ? "핀 해제" : "항상 위에 고정", action: onTogglePin)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                                    .frame(width: 20, height: 20)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .tint(.white.opacity(hovering ? 0.9 : 0.65))
                            .fixedSize()
                            .help("더 보기")
                            .popover(isPresented: $showingTablePicker, arrowEdge: .bottom) {
                                tableSizePicker
                            }
                        } else {
                            Button {
                                state.rememberActiveStickerEditor()
                                showingTablePicker = true
                            } label: {
                                Image(systemName: "tablecells")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .tint(.white.opacity(hovering ? 0.9 : 0.65))
                            .help("표 삽입")
                            .popover(isPresented: $showingTablePicker, arrowEdge: .bottom) {
                                tableSizePicker
                            }
                            Button(action: { state.showTextColorPanel() }) {
                                Image(systemName: "textformat")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help("선택한 글자 색상")
                            Button(action: { state.showColorPanel(for: id) }) {
                                Image(systemName: "paintpalette")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(hovering ? 0.9 : 0.65))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help("이 메모 색상")
                            Button(action: onTogglePin) {
                                Image(systemName: isPinned ? "pin.fill" : "pin")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(isPinned ? 1 : (hovering ? 0.9 : 0.6)))
                                    .rotationEffect(.degrees(isPinned ? 0 : 45))
                                    .frame(width: 20, height: 20)
                                    .help(isPinned ? "Unpin" : "Keep on top")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, compact ? 6 : 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 30)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { _ in onDrag() }
            )

            // Body
            RichTextEditor(
                text: richText,
                displayedFontSize: $displayedFontSize,
                fontSize: state.fontSize,
                fontStyle: state.noteFontStyle,
                fontWeight: state.noteFontWeight,
                fontColor: state.fontColor
            )
        }
        .background(FrostedBackground(
            state: state,
            backgroundColor: state.backgroundColor(for: id),
            cornerRadius: 14
        ))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        .overlay(alignment: .bottomTrailing) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 12))
                p.addQuadCurve(to: CGPoint(x: 12, y: 0), control: CGPoint(x: 12, y: 12))
            }
            .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 14, height: 14)
            .padding(8)
            .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
        .onChange(of: displayedFontSize) { _, newSize in
            guard !fontSizeFieldFocused else { return }
            fontSizeInput = "\(Int(newSize.rounded()))"
        }
        .onChange(of: fontSizeFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitFontSizeInput()
            }
        }
    }

    private func commitFontSizeInput() {
        let trimmed = fontSizeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed) else {
            fontSizeInput = "\(Int(displayedFontSize.rounded()))"
            return
        }
        let size = min(36, max(8, CGFloat(parsed).rounded()))
        fontSizeInput = "\(Int(size))"
        displayedFontSize = size
        state.setEditorFontSize(to: size)
    }
}

// MARK: - Sticker window

final class StickerWindow: NSWindow {
    let stickerID: UUID
    private static let interactiveDesktopLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
    )

    init(data: StickerData, state: AppState, onClose: @escaping (UUID) -> Void, onTogglePin: @escaping (UUID) -> Void) {
        self.stickerID = data.id
        super.init(
            contentRect: NSRect(x: data.x, y: data.y, width: data.width, height: data.height),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Hide native chrome but keep titled-window resize behavior (edge/corner
        // hit testing + system cursors). The SwiftUI body draws the visible UI.
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false // SwiftUI provides shadow
        self.minSize = NSSize(width: 160, height: 140)
        applyPinned(data.pinned)

        let id = data.id
        let view = StickerView(
            id: id,
            state: state,
            onClose: { onClose(id) },
            onDrag: { [weak self] in
                guard let self, let event = NSApp.currentEvent else { return }
                self.performDrag(with: event)
            },
            onTogglePin: { onTogglePin(id) }
        )
        let host = FirstMouseHostingView(rootView: view)
        self.contentView = host

        // Use AppKit tracking views inside the window instead of relying on
        // SwiftUI gestures at the native resize border. macOS can consume edge
        // drags before SwiftUI sees them, especially at desktop-level windows.
        let rightHandle = StickerResizeHandleView(axis: .horizontal)
        rightHandle.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rightHandle, positioned: .above, relativeTo: nil)

        let cornerHandle = StickerResizeHandleView(axis: .both)
        cornerHandle.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(cornerHandle, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            rightHandle.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            rightHandle.topAnchor.constraint(equalTo: host.topAnchor, constant: 30),
            rightHandle.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -38),
            rightHandle.widthAnchor.constraint(equalToConstant: 14),
            cornerHandle.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            cornerHandle.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            cornerHandle.widthAnchor.constraint(equalToConstant: 38),
            cornerHandle.heightAnchor.constraint(equalToConstant: 38)
        ])
        installActiveBlurFix(on: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Keep Liquid Glass `.clear` from desaturating when another app takes
    // focus. Glass reads `isMainWindow` to decide active vs. inactive look.
    override var isMainWindow: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func applyPinned(_ pinned: Bool) {
        let wasVisible = self.isVisible
        if pinned {
            self.level = .floating
            self.collectionBehavior = [.stationary, .canJoinAllSpaces]
            if wasVisible { self.orderFrontRegardless() }
        } else {
            // Above Finder's desktop/icon surface so the note remains clickable,
            // but far below normal app windows so it cannot flash over them.
            self.level = Self.interactiveDesktopLevel
            self.orderOut(nil)
            self.collectionBehavior = [.stationary, .canJoinAllSpaces]
            if wasVisible {
                self.orderBack(nil)
                self.resignKey()
            }
        }
    }

    /// Put a normal sticker behind the other windows on the desktop when the
    /// Stick app loses focus. Pinned stickers intentionally stay floating.
    func moveBehindOtherWindows() {
        guard !isPinnedWindow else { return }
        orderBack(nil)
        resignKey()
    }

    private var isPinnedWindow: Bool {
        level == .floating
    }

}

final class StickerResizeHandleView: NSView {
    enum Axis {
        case horizontal
        case both
    }

    private let axis: Axis

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation

        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseUp { break }

            let mouse = NSEvent.mouseLocation
            let deltaX = mouse.x - startMouse.x
            let deltaY = mouse.y - startMouse.y
            let width = max(window.minSize.width, startFrame.width + deltaX)
            let height = axis == .both
                ? max(window.minSize.height, startFrame.height - deltaY)
                : startFrame.height
            window.setFrame(
                NSRect(
                    x: startFrame.minX,
                    y: startFrame.maxY - height,
                    width: width,
                    height: height
                ),
                display: true
            )
        }
    }
}

// NSHostingView subclass that lets clicks reach the SwiftUI gestures even
// when the window is not key — so dragging a sticker by its title bar works
// on the very first mousedown instead of requiring an activation click first.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        forceActiveVisualEffects(in: self)
    }
}

// Walk subview tree and force every NSVisualEffectView (including those the
// SwiftUI `.glassEffect` hosts) to stay active when the window loses focus.
func forceActiveVisualEffects(in view: NSView) {
    if let ve = view as? NSVisualEffectView {
        ve.state = .active
    }
    for sub in view.subviews { forceActiveVisualEffects(in: sub) }
}

// Window mixin: re-force active state whenever key/main status changes.
func installActiveBlurFix(on window: NSWindow) {
    let nc = NotificationCenter.default
    let apply: (Notification) -> Void = { _ in
        guard let v = window.contentView else { return }
        DispatchQueue.main.async { forceActiveVisualEffects(in: v) }
    }
    for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                 NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
        nc.addObserver(forName: name, object: window, queue: .main, using: apply)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var state: AppState
    let onNew: () -> Void
    let onFocus: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onHide: () -> Void
    @State private var hoveredID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stick")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(state.fontColor)
                Spacer()
                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(state.fontColor.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Hide dashboard")
                Button(action: onNew) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        Text("New")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.primary.opacity(0.15))

            if state.stickers.isEmpty {
                VStack {
                    Spacer()
                    Text("No notes yet.\nTap + New to add one.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(state.fontColor.opacity(0.65))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.stickers.enumerated()), id: \.element.id) { idx, s in
                            StickerRow(
                                s: s,
                                state: state,
                                onFocus: { onFocus(s.id) },
                                onDelete: { onDelete(s.id) },
                                onHover: { isHover in
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        hoveredID = isHover ? s.id : (hoveredID == s.id ? nil : hoveredID)
                                    }
                                }
                            )
                            if idx < state.stickers.count - 1 {
                                let next = state.stickers[idx + 1].id
                                let hidden = hoveredID == s.id || hoveredID == next
                                Rectangle()
                                    .fill(Color.primary.opacity(hidden ? 0 : 0.08))
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                    .padding(10)
                }
            }

            Divider().background(Color.primary.opacity(0.15))

            SettingsPanel(state: state)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            Divider().background(Color.primary.opacity(0.15))

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(state.fontColor.opacity(0.65))
                Text(Store.shared.url.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(state.fontColor.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Store.shared.url.path)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                NSWorkspace.shared.activateFileViewerSelecting([Store.shared.url])
            }
        }
        .background(FrostedBackground(state: state, cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        .padding(10)
    }
}

struct StickerRow: View {
    let s: StickerData
    @ObservedObject var state: AppState
    let onFocus: () -> Void
    let onDelete: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    @State private var hover = false

    private var preview: String {
        let trimmed = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : trimmed
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.primary.opacity(0.7)).frame(width: 6, height: 6)
            Text(preview)
                .lineLimit(1)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(state.fontColor)
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(state.fontColor)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.18)) { hover = h }
            onHover(h)
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var state: AppState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Appearance")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                    Spacer()
                }
                .foregroundColor(state.fontColor.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Group {
                    sectionLabel("Text")
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 10))
                            .foregroundColor(state.fontColor.opacity(0.6))
                            .frame(width: 12)
                        Text("글자 크기")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(state.fontColor.opacity(0.65))
                        Spacer()
                        Button(action: { state.adjustDefaultFontSize(by: -1) }) {
                            Image(systemName: "minus")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        Text("\(Int(state.fontSize.rounded()))pt")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(state.fontColor.opacity(0.8))
                            .frame(width: 34)
                        Button(action: { state.adjustDefaultFontSize(by: 1) }) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "textformat")
                            .font(.system(size: 10))
                            .foregroundColor(state.fontColor.opacity(0.6))
                            .frame(width: 12)
                        Text("폰트")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(state.fontColor.opacity(0.65))
                        Spacer()
                        Picker("폰트", selection: $state.noteFontStyle) {
                            ForEach(NoteFontStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                    Picker("굵기", selection: $state.noteFontWeight) {
                        ForEach(NoteFontWeight.allCases) { weight in
                            Text(weight.title).tag(weight)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    colorRow(icon: "paintpalette", label: "Font color", selection: $state.fontColor)

                    Divider().padding(.vertical, 4)

                    sectionLabel("Background")
                    Picker("", selection: $state.glassVariant) {
                        Text("Regular").tag(0)
                        Text("Clear").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    if state.glassVariant == 0 {
                        colorRow(icon: "paintbrush", label: "Background color", selection: $state.bgColor)
                        sliderRow("circle.lefthalf.filled", $state.regularBgOpacity)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundColor(state.fontColor.opacity(0.55))
            .tracking(0.5)
            .padding(.top, 2)
    }

    private func colorRow(icon: String, label: String, selection: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(state.fontColor.opacity(0.6))
                .frame(width: 12)
            ColorPicker(label, selection: selection, supportsOpacity: true)
                .labelsHidden()
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(state.fontColor.opacity(0.65))
            Spacer()
        }
    }

    private func sliderRow(_ icon: String, _ binding: Binding<CGFloat>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(state.fontColor.opacity(0.6))
                .frame(width: 12)
            Slider(value: Binding(
                get: { Double(binding.wrappedValue) },
                set: { binding.wrappedValue = CGFloat($0) }
            ), in: 0...1)
            .controlSize(.mini)
        }
    }
}

final class DashboardWindow: NSWindow {
    init(rootView: NSView) {
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 360),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .normal
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces]
        self.minSize = NSSize(width: 240, height: 240)
        self.contentView = rootView
        installActiveBlurFix(on: self)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isMainWindow: Bool { true }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var stickerWindows: [UUID: StickerWindow] = [:]
    private var dashboard: DashboardWindow?
    private var statusItem: NSStatusItem!
    private var observers: [NSObjectProtocol] = []
    private var hotKeyHandler: EventHandlerRef?
    private var newNoteHotKey: EventHotKeyRef?
    private var dashboardHotKey: EventHotKeyRef?
    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var missionControlMonitor: DispatchSourceTimer?
    private var missionControlWasVisible = false
    private var missionControlRestoreWorkItem: DispatchWorkItem?

    private static let hotKeySignature: OSType = 0x5354494B // "STIK"
    private enum GlobalHotKey: UInt32 {
        case newNote = 1
        case dashboard = 2
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        installEditMenu()
        installTypingShortcuts()
        startMissionControlMonitor()

        // Menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Stick")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        let mNew = NSMenuItem(title: "New Note", action: #selector(menuNew), keyEquivalent: "n")
        mNew.keyEquivalentModifierMask = [.command, .option]
        mNew.target = self
        menu.addItem(mNew)
        let mDash = NSMenuItem(title: "Show / Hide Dashboard", action: #selector(toggleDashboard), keyEquivalent: "s")
        mDash.keyEquivalentModifierMask = [.command, .option]
        mDash.target = self
        menu.addItem(mDash)
        menu.addItem(.separator())
        let mQuit = NSMenuItem(title: "Quit Stick", action: #selector(menuQuit), keyEquivalent: "q")
        mQuit.target = self
        menu.addItem(mQuit)
        statusItem.menu = menu

        registerGlobalHotKeys()

        // Load
        state.stickers = Store.shared.load()
        for s in state.stickers { spawnWindow(for: s) }

        // Dashboard
        showDashboard()

        // Keep window frames in sync
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] n in
            self?.syncFrame(n)
        })
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] n in
            self?.syncFrame(n)
        })
        // Reposition color panel next to dashboard whenever it appears.
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let panel = n.object as? NSColorPanel, let dash = self?.dashboard else { return }
            let d = dash.frame
            let p = panel.frame
            var x = d.minX - p.width - 8
            if x < 8 { x = d.maxX + 8 }
            let y = max(8, d.maxY - p.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let panel = n.object as? NSColorPanel else { return }
            self?.state.endColorPanelSession(panel)
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.sendStickersToBack()
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.save(state.stickers)
        unregisterGlobalHotKeys()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        missionControlMonitor?.cancel()
        missionControlRestoreWorkItem?.cancel()
    }

    @objc func menuNew() { newSticker() }
    @objc func menuQuit() { NSApp.terminate(nil) }
    @objc func undoTextEdit() {
        NSApp.keyWindow?.firstResponder?.undoManager?.undo()
    }
    @objc func redoTextEdit() {
        NSApp.keyWindow?.firstResponder?.undoManager?.redo()
    }

    private func installTypingShortcuts() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty,
                  let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
                return event
            }

            if event.keyCode == UInt16(kVK_Return) ||
                event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                if !event.modifierFlags.contains(.shift),
                   self.insertHorizontalRuleIfNeeded(in: textView) {
                    return nil
                }
                return event
            }

            guard event.keyCode == UInt16(kVK_Space) else { return event }

            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location > 0 else { return event }
            let text = textView.string as NSString

            if selection.location >= 2 {
                let taskRange = NSRange(location: selection.location - 2, length: 2)
                let isLineStart = taskRange.location == 0 ||
                    text.substring(with: NSRange(location: taskRange.location - 1, length: 1)) == "\n"
                if isLineStart, text.substring(with: taskRange) == "[]" {
                    textView.insertText("☐ ", replacementRange: taskRange)
                    return nil
                }
            }

            let dashRange = NSRange(location: selection.location - 1, length: 1)
            guard NSMaxRange(dashRange) <= text.length,
                  text.substring(with: dashRange) == "-" else {
                return event
            }
            guard dashRange.location == 0 ||
                    text.substring(with: NSRange(location: dashRange.location - 1, length: 1)) == "\n" else {
                return event
            }

            let baseFont = textView.textStorage?.attribute(
                .font,
                at: dashRange.location,
                effectiveRange: nil
            ) as? NSFont ?? textView.font ?? NSFont.systemFont(ofSize: 14)
            let bulletFont = baseFont

            var bulletAttributes = textView.typingAttributes
            bulletAttributes[.font] = bulletFont
            let paragraphStyle = bulletParagraphStyle(
                from: textView.typingAttributes[.paragraphStyle]
            )
            bulletAttributes[.paragraphStyle] = paragraphStyle
            var tabAttributes = textView.typingAttributes
            tabAttributes[.font] = baseFont
            tabAttributes[.paragraphStyle] = paragraphStyle

            let replacement = NSMutableAttributedString(
                string: "•",
                attributes: bulletAttributes
            )
            replacement.append(NSAttributedString(string: "\t", attributes: tabAttributes))
            textView.insertText(replacement, replacementRange: dashRange)
            var typingAttributes = textView.typingAttributes
            typingAttributes[.font] = baseFont
            typingAttributes[.paragraphStyle] = paragraphStyle
            textView.typingAttributes = typingAttributes
            return nil
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            return self.toggleChecklistItem(at: event) ? nil : event
        }
    }

    private func insertHorizontalRuleIfNeeded(in textView: NSTextView) -> Bool {
        guard let fixedTextView = textView as? FixedFontTextView,
              let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location >= 3 else { return false }

        let source = textView.string as NSString
        let prefix = source.substring(to: selection.location) as NSString
        let previousNewline = prefix.range(of: "\n", options: .backwards)
        let lineStart = previousNewline.location == NSNotFound
            ? 0
            : NSMaxRange(previousNewline)
        let markerRange = NSRange(
            location: lineStart,
            length: selection.location - lineStart
        )
        guard source.substring(with: markerRange) == "---" else { return false }

        let baseAttributes = markerRange.location < storage.length
            ? storage.attributes(at: markerRange.location, effectiveRange: nil)
            : textView.typingAttributes
        let baseFont = baseAttributes[.font] as? NSFont
            ?? textView.typingAttributes[.font] as? NSFont
            ?? textView.font
            ?? NSFont.systemFont(ofSize: state.fontSize)
        let glyphWidth = max(
            1,
            ("─" as NSString).size(withAttributes: [.font: baseFont]).width
        )
        let insetWidth = textView.textContainerInset.width * 2
        let availableWidth = max(70, textView.bounds.width - insetWidth - 8)
        let glyphCount = max(8, Int(floor(availableWidth / glyphWidth * 0.92)))

        let replacement = NSMutableAttributedString(
            string: String(repeating: "─", count: glyphCount),
            attributes: baseAttributes
        )
        var newLineAttributes = textView.typingAttributes
        newLineAttributes[.font] = defaultNewLineFont(in: textView)
        replacement.append(NSAttributedString(string: "\n", attributes: newLineAttributes))

        return fixedTextView.replaceWithUndo(
            range: markerRange,
            with: replacement,
            selectedRangeAfter: NSRange(
                location: markerRange.location + replacement.length,
                length: 0
            ),
            actionName: "구분선"
        )
    }

    private func defaultNewLineFont(in textView: NSTextView) -> NSFont {
        let currentFont = textView.typingAttributes[.font] as? NSFont
            ?? textView.font
            ?? NSFont.systemFont(ofSize: 12)
        let baseFont = (textView as? FixedFontTextView)?.fixedFont ?? currentFont
        let manager = NSFontManager.shared
        var font = NSFont(descriptor: baseFont.fontDescriptor, size: 12)
            ?? NSFont.systemFont(ofSize: 12)
        let traits = manager.traits(of: currentFont)
        if traits.contains(.boldFontMask) {
            font = manager.convert(font, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italicFontMask) {
            font = manager.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private func toggleChecklistItem(at event: NSEvent) -> Bool {
        guard let window = event.window,
              let contentView = window.contentView else { return false }
        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        var hitView: NSView? = contentView.hitTest(contentPoint)
        while hitView != nil, !(hitView is NSTextView) {
            hitView = hitView?.superview
        }
        guard let textView = hitView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return false }

        let localPoint = textView.convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: localPoint.x - textView.textContainerOrigin.x,
            y: localPoint.y - textView.textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return false }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        ).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        guard glyphRect.insetBy(dx: -3, dy: -3).contains(localPoint) else { return false }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let text = textView.string as NSString
        guard characterIndex < text.length else { return false }
        let characterRange = NSRange(location: characterIndex, length: 1)
        let character = text.substring(with: characterRange)
        guard character == "☐" || character == "☑" else { return false }

        let lineRange = text.lineRange(for: characterRange)
        guard characterIndex == lineRange.location,
              let storage = textView.textStorage,
              textView.shouldChangeText(in: lineRange, replacementString: nil) else { return false }

        storage.beginEditing()
        storage.replaceCharacters(in: characterRange, with: character == "☐" ? "☑" : "☐")
        var contentStart = characterIndex + 1
        if contentStart < text.length,
           text.substring(with: NSRange(location: contentStart, length: 1)) == " " {
            contentStart += 1
        }
        var contentEnd = NSMaxRange(lineRange)
        if contentEnd > contentStart,
           text.substring(with: NSRange(location: contentEnd - 1, length: 1)) == "\n" {
            contentEnd -= 1
        }
        let contentRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
        if contentRange.length > 0 {
            if character == "☐" {
                storage.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: contentRange
                )
            } else {
                storage.removeAttribute(.strikethroughStyle, range: contentRange)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        window.makeFirstResponder(textView)
        return true
    }

    @objc func toggleSelectionBold() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }

        let manager = NSFontManager.shared
        let selectedRange = textView.selectedRange()
        let fallbackFont = textView.font ?? NSFont.systemFont(ofSize: state.fontSize)

        func toggledFont(_ font: NSFont, makeBold: Bool) -> NSFont {
            if makeBold {
                return manager.convert(font, toHaveTrait: .boldFontMask)
            }
            return manager.convert(font, toNotHaveTrait: .boldFontMask)
        }

        if selectedRange.length == 0 {
            var attributes = textView.typingAttributes
            let currentFont = attributes[.font] as? NSFont ?? fallbackFont
            let makeBold = !manager.traits(of: currentFont).contains(.boldFontMask)
            attributes[.font] = toggledFont(currentFont, makeBold: makeBold)
            textView.typingAttributes = attributes
            return
        }

        guard let storage = textView.textStorage, selectedRange.location < storage.length else { return }
        let sampleFont = storage.attribute(.font, at: selectedRange.location, effectiveRange: nil) as? NSFont ?? fallbackFont
        let makeBold = !manager.traits(of: sampleFont).contains(.boldFontMask)
        var updates: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
            let font = value as? NSFont ?? fallbackFont
            updates.append((range, toggledFont(font, makeBold: makeBold)))
        }
        storage.beginEditing()
        for (range, font) in updates {
            storage.addAttribute(.font, value: font, range: range)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    @objc func toggleSelectionStrikethrough() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0,
              let storage = textView.textStorage,
              selectedRange.location < storage.length,
              textView.shouldChangeText(in: selectedRange, replacementString: nil) else {
            NSSound.beep()
            return
        }

        let currentValue = storage.attribute(
            .strikethroughStyle,
            at: selectedRange.location,
            effectiveRange: nil
        ) as? NSNumber
        storage.beginEditing()
        if (currentValue?.intValue ?? 0) == 0 {
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: selectedRange
            )
        } else {
            storage.removeAttribute(.strikethroughStyle, range: selectedRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    /// The accessory app has no default application menu. Without an Edit
    /// menu, AppKit does not route the standard Command-X/C/V actions from a
    /// TextEditor through the responder chain.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(title: "Stick", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Stick", action: #selector(menuQuit), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "실행 취소", action: #selector(undoTextEdit), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = self
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "다시 실행", action: #selector(redoTextEdit), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let boldItem = editMenu.addItem(
            withTitle: "선택 부분 보통 / 굵게 전환",
            action: #selector(toggleSelectionBold),
            keyEquivalent: "b"
        )
        boldItem.target = self
        let strikethroughItem = editMenu.addItem(
            withTitle: "선택 부분 취소선 전환",
            action: #selector(toggleSelectionStrikethrough),
            keyEquivalent: "x"
        )
        strikethroughItem.keyEquivalentModifierMask = [.command, .option]
        strikethroughItem.target = self
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc func toggleDashboard() {
        if let d = dashboard, d.isVisible {
            d.orderOut(nil)
        } else {
            showDashboard()
        }
    }

    private func showDashboard() {
        if dashboard == nil {
            let host = NSHostingView(rootView: DashboardView(
                state: state,
                onNew: { [weak self] in self?.newSticker() },
                onFocus: { [weak self] id in self?.focusSticker(id) },
                onDelete: { [weak self] id in self?.deleteSticker(id) },
                onHide: { [weak self] in self?.dashboard?.orderOut(nil) }
            ))
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
            host.autoresizingMask = [.width, .height]
            dashboard = DashboardWindow(rootView: host)
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                dashboard?.setFrameOrigin(NSPoint(x: f.maxX - 300, y: f.maxY - 380))
            }
        }
        dashboard?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func newSticker() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 200, y: 200, width: 240, height: 200)
        let s = StickerData(
            id: UUID(),
            text: "",
            x: frame.midX - 120 + CGFloat.random(in: -80...80),
            y: frame.midY - 100 + CGFloat.random(in: -80...80),
            width: 240, height: 200
        )
        state.upsert(s)
        spawnWindow(for: s, focusForTyping: true)
    }

    private func spawnWindow(for s: StickerData, focusForTyping: Bool = false) {
        let w = StickerWindow(
            data: s,
            state: state,
            onClose: { [weak self] id in self?.closeStickerWindow(id) },
            onTogglePin: { [weak self] id in self?.togglePin(id) }
        )
        stickerWindows[s.id] = w
        if missionControlWasVisible { w.alphaValue = 0 }
        w.orderFrontRegardless()
        if focusForTyping {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            focusEditor(in: w)
        }
    }

    private func focusEditor(in window: NSWindow, attempt: Int = 0) {
        if let textView = firstTextView(in: window.contentView) {
            window.makeFirstResponder(textView)
            return
        }
        guard attempt < 5 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
            guard let self, let window else { return }
            self.focusEditor(in: window, attempt: attempt + 1)
        }
    }

    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = firstTextView(in: subview) { return textView }
        }
        return nil
    }

    private func startMissionControlMonitor() {
        // Do not force the Accessibility prompt at launch. If permission has
        // already been granted, the monitor works normally; otherwise it stays
        // inactive until the user enables Stick in System Settings.
        let queue = DispatchQueue(label: "com.jvalaj.stick.mission-control-monitor", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            let isVisible = autoreleasepool { Self.dockShowsMissionControl() }
            DispatchQueue.main.async {
                self?.setMissionControlVisible(isVisible)
            }
        }
        missionControlMonitor = timer
        timer.resume()
    }

    private static func dockShowsMissionControl() -> Bool {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
              ).first else {
            return false
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            dockElement,
            kAXChildrenAttribute as CFString,
            &rawChildren
        ) == .success,
        let children = rawChildren as? [AXUIElement] else {
            return false
        }

        for child in children {
            var rawIdentifier: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                child,
                kAXIdentifierAttribute as CFString,
                &rawIdentifier
            ) == .success else { continue }
            if rawIdentifier as? String == "mc" { return true }
        }
        return false
    }

    private func setMissionControlVisible(_ isVisible: Bool) {
        guard isVisible != missionControlWasVisible else { return }
        missionControlWasVisible = isVisible

        if isVisible {
            missionControlRestoreWorkItem?.cancel()
            for window in stickerWindows.values {
                window.alphaValue = 0
            }
            return
        }

        missionControlRestoreWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.missionControlWasVisible else { return }
            for window in self.stickerWindows.values {
                window.alphaValue = 1
            }
        }
        missionControlRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func registerGlobalHotKeys() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let delegate = Unmanaged<AppDelegate>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case GlobalHotKey.newNote.rawValue:
                        delegate.newSticker()
                    case GlobalHotKey.dashboard.rawValue:
                        delegate.toggleDashboard()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )
        UserDefaults.standard.set(Int(handlerStatus), forKey: "hotKeyHandlerRegistrationStatus")
        guard handlerStatus == noErr else { return }

        let modifiers = UInt32(cmdKey | optionKey)
        let newNoteStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            modifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: GlobalHotKey.newNote.rawValue),
            GetApplicationEventTarget(),
            0,
            &newNoteHotKey
        )
        let dashboardStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            modifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: GlobalHotKey.dashboard.rawValue),
            GetApplicationEventTarget(),
            0,
            &dashboardHotKey
        )
        UserDefaults.standard.set(Int(newNoteStatus), forKey: "newNoteHotKeyRegistrationStatus")
        UserDefaults.standard.set(Int(dashboardStatus), forKey: "dashboardHotKeyRegistrationStatus")
    }

    private func unregisterGlobalHotKeys() {
        if let newNoteHotKey { UnregisterEventHotKey(newNoteHotKey) }
        if let dashboardHotKey { UnregisterEventHotKey(dashboardHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    private func togglePin(_ id: UUID) {
        guard var s = state.sticker(id) else { return }
        s.pinned.toggle()
        state.upsert(s)
        stickerWindows[id]?.applyPinned(s.pinned)
    }

    private func closeStickerWindow(_ id: UUID) {
        // Respect an explicitly hidden dashboard. Closing a note should not
        // unexpectedly bring the menu window back after the user clicked the
        // eye button.
        let dashboardWasVisible = dashboard?.isVisible == true
        if let w = stickerWindows.removeValue(forKey: id) {
            w.orderOut(nil)
        }
        if dashboardWasVisible {
            showDashboard()
        }
    }

    private func focusSticker(_ id: UUID) {
        if let w = stickerWindows[id] {
            w.orderFrontRegardless()
            w.makeKey()
            return
        }
        guard let s = state.sticker(id) else { return }
        spawnWindow(for: s)
        stickerWindows[id]?.makeKey()
    }

    private func sendStickersToBack() {
        for window in stickerWindows.values {
            window.moveBehindOtherWindows()
        }
    }

    private func deleteSticker(_ id: UUID) {
        if let w = stickerWindows.removeValue(forKey: id) {
            w.orderOut(nil)
            w.close()
        }
        state.remove(id)
    }

    private func syncFrame(_ note: Notification) {
        guard let w = note.object as? StickerWindow else { return }
        guard var s = state.sticker(w.stickerID) else { return }
        let f = w.frame
        s.x = f.origin.x; s.y = f.origin.y
        s.width = f.size.width; s.height = f.size.height
        state.upsert(s)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
