//
//  JSONTextEditor.swift
//  fil's editor
//

import AppKit
import Combine
import SwiftUI

// MARK: - Controller (toolbar → text view commands)

final class JSONTextController: ObservableObject {
    @Published private(set) var zoomPercent = 100

    weak var textView: JSONTextView? {
        didSet {
            textView?.onZoomChange = { [weak self] percent in
                self?.zoomPercent = percent
            }
        }
    }

    func zoomIn() { textView?.zoom(by: JSONTextView.zoomStep) }
    func zoomOut() { textView?.zoom(by: -JSONTextView.zoomStep) }
    func resetZoom() { textView?.setFontSize(JSONTextView.defaultFontSize) }

    func replaceAll(with newText: String, actionName: String) {
        guard let textView, let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard textView.shouldChangeText(in: fullRange, replacementString: newText) else { return }
        textStorage.replaceCharacters(
            in: fullRange,
            with: NSAttributedString(string: newText, attributes: textView.baseAttributes)
        )
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        let start = NSRange(location: 0, length: 0)
        textView.setSelectedRange(start)
        textView.scrollRangeToVisible(start)
    }

    func showFind(replace: Bool) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = (replace ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        textView.performTextFinderAction(sender)
    }

    func goTo(line: Int, column: Int) {
        guard let textView else { return }
        let units = Array(textView.string.utf16)
        var offset = 0
        var currentLine = 1
        while currentLine < line, offset < units.count {
            if units[offset] == 10 { currentLine += 1 }
            offset += 1
        }
        var currentColumn = 1
        while currentColumn < column, offset < units.count, units[offset] != 10 {
            offset += 1
            currentColumn += 1
        }
        let caret = NSRange(location: offset, length: 0)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
        if offset < units.count {
            textView.showFindIndicator(for: NSRange(location: offset, length: 1))
        }
    }
}

// MARK: - Text view wrapper

/// NSTextView-based editor used for JSON and YAML; `language` picks the syntax highlighter.
struct JSONTextEditor: NSViewRepresentable {
    let text: String
    let language: StructuredTextLanguage
    let controller: JSONTextController
    let undoManager: UndoManager?
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> JSONEditorContainerView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let unlimited = CGFloat.greatestFiniteMagnitude
        let textContainer = NSTextContainer(size: NSSize(width: unlimited, height: unlimited))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        // Sized by JSONScrollView.layout(); autoresizing a flipped document view shifts its origin.
        let textView = JSONTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: textContainer)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: unlimited, height: unlimited)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 4, height: 4)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = textView.editorFont
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.typingAttributes = textView.baseAttributes

        textStorage.setAttributedString(NSAttributedString(string: text, attributes: textView.baseAttributes))
        language.highlight(textStorage, baseAttributes: textView.baseAttributes)
        textView.delegate = context.coordinator

        let scrollView = JSONScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        let container = JSONEditorContainerView(scrollView: scrollView, textView: textView)
        controller.textView = textView
        context.coordinator.textView = textView
        return container
    }

    func updateNSView(_ container: JSONEditorContainerView, context: Context) {
        context.coordinator.parent = self
        controller.textView = context.coordinator.textView
        guard let textView = context.coordinator.textView,
              let textStorage = textView.textStorage,
              textView.string != text else { return }
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: textView.baseAttributes))
        language.highlight(textStorage, baseAttributes: textView.baseAttributes)
        container.scrollView.refreshLayout()
        container.gutter.recomputeLineStarts()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONTextEditor
        weak var textView: JSONTextView?
        private var pendingHighlight: DispatchWorkItem?

        init(parent: JSONTextEditor) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            parent.undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onTextChange(textView.string)
            scheduleHighlight()
        }

        private func scheduleHighlight() {
            pendingHighlight?.cancel()
            guard let textView, let textStorage = textView.textStorage else { return }
            let length = textStorage.length
            guard length <= JSONSyntaxHighlighter.maximumLength else { return }

            if length <= 200_000 {
                if !textView.hasMarkedText() {
                    parent.language.highlight(textStorage, baseAttributes: textView.baseAttributes)
                }
                return
            }

            let work = DispatchWorkItem { [weak self] in
                guard let textView = self?.textView,
                      let textStorage = textView.textStorage,
                      !textView.hasMarkedText(),
                      let language = self?.parent.language else { return }
                language.highlight(textStorage, baseAttributes: textView.baseAttributes)
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}

// MARK: - Scroll view

final class JSONScrollView: NSScrollView {
    var onVisibleAreaChange: (() -> Void)?
    private var didScrollToStart = false

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onVisibleAreaChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didScrollToStart else { return }
        didScrollToStart = true
        // Wait for the first layout pass so the clip view has its final size.
        DispatchQueue.main.async { [weak self] in
            self?.scrollToStart()
        }
    }

    override func layout() {
        super.layout()
        refreshLayout()
    }

    /// Keeps the text view at the clip view's origin and at least as large as the visible area.
    func refreshLayout() {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let visibleSize = contentView.bounds.size
        if textView.minSize != visibleSize {
            textView.minSize = visibleSize
        }
        if textView.frame.origin != .zero {
            textView.setFrameOrigin(.zero)
        }
        layoutManager.ensureLayout(for: textContainer)
        textView.sizeToFit()
        onVisibleAreaChange?()
    }

    func scrollToStart() {
        layoutSubtreeIfNeeded()
        refreshLayout()
        (documentView as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 0))
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
        documentView?.needsDisplay = true
        onVisibleAreaChange?()
    }
}

// MARK: - Text view with zoom

final class JSONTextView: NSTextView {
    static let defaultFontSize: CGFloat = 12
    static let minimumFontSize: CGFloat = 6
    static let maximumFontSize: CGFloat = 48
    static let zoomStep: CGFloat = 1

    var onZoomChange: ((Int) -> Void)?
    var onFontSizeChange: (() -> Void)?
    private(set) var fontSize = JSONTextView.defaultFontSize
    /// Unrounded size tracked during continuous gestures so tiny deltas still add up.
    private var continuousFontSize = JSONTextView.defaultFontSize

    var editorFont: NSFont {
        .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: editorFont, .foregroundColor: NSColor.labelColor]
    }

    var zoomPercent: Int {
        Int((fontSize / Self.defaultFontSize * 100).rounded())
    }

    // Trackpad pinch
    override func magnify(with event: NSEvent) {
        if event.phase == .began {
            continuousFontSize = fontSize
        }
        continuousFontSize *= 1 + event.magnification
        applyContinuousFontSize()
    }

    // ⌘ or Ctrl + scroll wheel (Ctrl is the usual zoom modifier on Linux/Windows)
    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) || modifiers.contains(.control) else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began {
            continuousFontSize = fontSize
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.05 : event.scrollingDeltaY
        guard delta != 0 else { return }
        if !event.hasPreciseScrollingDeltas {
            continuousFontSize = fontSize
        }
        continuousFontSize += delta
        applyContinuousFontSize()
    }

    // ⌘ + / ⌘ - / ⌘ 0
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleZoomKey(event, modifier: .command) { return true }
        return super.performKeyEquivalent(with: event)
    }

    // Ctrl + / Ctrl - / Ctrl 0
    override func keyDown(with event: NSEvent) {
        if handleZoomKey(event, modifier: .control) { return }
        super.keyDown(with: event)
    }

    private func handleZoomKey(_ event: NSEvent, modifier: NSEvent.ModifierFlags) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers == modifier, let key = event.charactersIgnoringModifiers else { return false }
        switch key {
        case "+", "=": zoom(by: Self.zoomStep)
        case "-", "_": zoom(by: -Self.zoomStep)
        case "0": setFontSize(Self.defaultFontSize)
        default: return false
        }
        return true
    }

    func zoom(by delta: CGFloat) {
        setFontSize(fontSize + delta)
    }

    private func applyContinuousFontSize() {
        continuousFontSize = min(max(continuousFontSize, Self.minimumFontSize), Self.maximumFontSize)
        setFontSize(continuousFontSize, keepContinuousValue: true)
    }

    func setFontSize(_ requestedSize: CGFloat, keepContinuousValue: Bool = false) {
        let rounded = (requestedSize * 2).rounded() / 2
        let newSize = min(max(rounded, Self.minimumFontSize), Self.maximumFontSize)
        if !keepContinuousValue {
            continuousFontSize = newSize
        }
        guard newSize != fontSize else { return }

        let anchor = topVisibleCharacterIndex()
        fontSize = newSize
        font = editorFont
        typingAttributes = baseAttributes
        if let textStorage, textStorage.length > 0 {
            textStorage.beginEditing()
            textStorage.addAttribute(.font, value: editorFont, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
        }
        (enclosingScrollView as? JSONScrollView)?.refreshLayout()
        if let anchor {
            scrollCharacterToTop(anchor)
        }
        onFontSizeChange?()
        onZoomChange?(zoomPercent)
    }

    private func topVisibleCharacterIndex() -> Int? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let point = NSPoint(x: 0, y: max(0, visibleRect.minY - textContainerOrigin.y))
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    private func scrollCharacterToTop(_ characterIndex: Int) {
        guard let layoutManager, let textStorage, characterIndex < textStorage.length else { return }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        scroll(NSPoint(x: visibleRect.minX, y: fragment.minY + textContainerOrigin.y))
    }
}

// MARK: - Container (gutter beside the scroll view)

/// Keeps line numbers outside the scroll view: an NSRulerView overlaps the text on macOS 26
/// and gets mirrored into the toolbar by the scroll edge effect.
final class JSONEditorContainerView: NSView {
    let scrollView: JSONScrollView
    let gutter: LineNumberGutterView

    init(scrollView: JSONScrollView, textView: JSONTextView) {
        self.scrollView = scrollView
        gutter = LineNumberGutterView(scrollView: scrollView, textView: textView)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        addSubview(gutter)
        addSubview(scrollView)
        gutter.onWidthChange = { [weak self] in self?.needsLayout = true }
        textView.onFontSizeChange = { [weak self] in self?.gutter.fontSizeDidChange() }
        scrollView.onVisibleAreaChange = { [weak self] in self?.gutter.needsDisplay = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let gutterWidth = gutter.preferredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
    }
}

// MARK: - Syntax highlighting

enum JSONSyntaxHighlighter {
    static let maximumLength = 5_000_000

    private static let keyColor = NSColor.systemBlue
    private static let stringColor = NSColor.systemRed
    private static let numberColor = NSColor.systemOrange
    private static let literalColor = NSColor.systemPink
    private static let punctuationColor = NSColor.secondaryLabelColor

    static func highlight(_ textStorage: NSTextStorage, baseAttributes: [NSAttributedString.Key: Any]) {
        let units = Array(textStorage.string.utf16)
        let count = units.count
        guard count <= maximumLength else { return }

        textStorage.beginEditing()
        textStorage.addAttributes(baseAttributes, range: NSRange(location: 0, length: count))

        func color(_ start: Int, _ end: Int, _ color: NSColor) {
            guard end > start else { return }
            textStorage.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: end - start))
        }

        var i = 0
        while i < count {
            let unit = units[i]
            switch unit {
            case 34: // "
                let start = i
                i += 1
                while i < count {
                    let stringUnit = units[i]
                    if stringUnit == 92 { i += 2; continue }
                    i += 1
                    if stringUnit == 34 || stringUnit == 10 { break }
                }
                i = min(i, count)
                var next = i
                while next < count, JSONTools.isWhitespace(units[next]) { next += 1 }
                let isKey = next < count && units[next] == 58
                color(start, i, isKey ? keyColor : stringColor)
            case 45, 48...57: // - 0-9
                let start = i
                i += 1
                while i < count, isNumberPart(units[i]) { i += 1 }
                color(start, i, numberColor)
            case 97...122: // a-z
                let start = i
                while i < count, (97...122).contains(units[i]) { i += 1 }
                let word = units[start..<i]
                if word.elementsEqual("true".utf16) || word.elementsEqual("false".utf16) || word.elementsEqual("null".utf16) {
                    color(start, i, literalColor)
                }
            case 123, 125, 91, 93, 44, 58: // { } [ ] , :
                color(i, i + 1, punctuationColor)
                i += 1
            default:
                i += 1
            }
        }

        textStorage.endEditing()
    }

    private static func isNumberPart(_ unit: UInt16) -> Bool {
        (48...57).contains(unit) || unit == 46 || unit == 101 || unit == 69 || unit == 43 || unit == 45
    }
}

// MARK: - Line numbers

final class LineNumberGutterView: NSView {
    var onWidthChange: (() -> Void)?
    private(set) var preferredWidth: CGFloat = 40
    private weak var scrollView: NSScrollView?
    private weak var textView: JSONTextView?
    private var lineStarts: [Int] = [0]
    private var labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, textView: JSONTextView) {
        self.scrollView = scrollView
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 400))
        clipsToBounds = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        recomputeLineStarts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func recomputeLineStarts() {
        guard let textView else { return }
        var starts = [0]
        var index = 0
        for unit in textView.string.utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        lineStarts = starts
        updateWidth()
    }

    func fontSizeDidChange() {
        updateWidth()
    }

    private func updateWidth() {
        let labelSize = max(8, (textView?.fontSize ?? JSONTextView.defaultFontSize) * 0.85)
        if labelFont.pointSize != labelSize {
            labelFont = .monospacedDigitSystemFont(ofSize: labelSize, weight: .regular)
        }
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: labelFont]).width
        let digits = max(3, String(lineStarts.count).count)
        let width = (CGFloat(digits) * digitWidth + 16).rounded(.up)
        if abs(preferredWidth - width) > 0.5 {
            preferredWidth = width
            onWidthChange?()
        }
        needsDisplay = true
    }

    @objc private func textDidChange(_ notification: Notification) {
        recomputeLineStarts()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let scrollView,
              let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let length = (textView.string as NSString).length
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let containerOrigin = textView.textContainerOrigin
        let scrollOffset = scrollView.contentView.bounds.minY

        var line = lineIndex(containing: characterRange.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characterRange) { break }

            let fragment: NSRect
            if start < length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            } else if layoutManager.extraLineFragmentTextContainer != nil {
                fragment = layoutManager.extraLineFragmentRect
            } else {
                break
            }

            let top = fragment.minY + containerOrigin.y - scrollOffset
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.width - size.width - 8, y: top + (fragment.height - size.height) / 2),
                withAttributes: attributes
            )
            line += 1
        }
    }

    private func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
