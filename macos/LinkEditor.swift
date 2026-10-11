import AppKit
import SwiftUI

// The placeholder uses the same TextKit layout as editable text, including
// the font, line padding and container origin. It is not a SwiftUI overlay.
final class LinkTextView: NSTextView {
    private let documentStorage = NSTextStorage()
    private let hintStorage = NSTextStorage()
    private let hintLayout = NSLayoutManager()
    private let hintContainer = NSTextContainer()
    var onFocusChange: ((Bool) -> Void)?

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        let container = textContainer ?? NSTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        if textContainer == nil {
            let layout = NSLayoutManager()
            documentStorage.addLayoutManager(layout)
            layout.addTextContainer(container)
        }
        super.init(frame: frame, textContainer: container)
        hintStorage.addLayoutManager(hintLayout)
        hintLayout.addTextContainer(hintContainer)
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        allowsUndo = true
        drawsBackground = false
        font = .systemFont(ofSize: 14)
        textColor = .labelColor
        insertionPointColor = .labelColor
        textContainerInset = NSSize(width: 12, height: 10)
        self.textContainer?.lineFragmentPadding = 0
        self.textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityLabel("影片链接")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var placeholderOrigin: NSPoint { textContainerOrigin }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let textContainer, let font else { return }
        hintStorage.setAttributedString(NSAttributedString(string: "粘贴影片链接", attributes: [
            .font: font, .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default
        ]))
        hintContainer.containerSize = textContainer.containerSize
        hintContainer.lineFragmentPadding = textContainer.lineFragmentPadding
        hintLayout.usesFontLeading = layoutManager?.usesFontLeading ?? true
        let range = hintLayout.glyphRange(for: hintContainer)
        hintLayout.drawGlyphs(forGlyphRange: range, at: placeholderOrigin)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

struct LinkEditor: NSViewRepresentable {
    @Binding var text: String
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = LinkTextView(frame: scroll.bounds, textContainer: nil)
        editor.delegate = context.coordinator
        editor.onFocusChange = onFocusChange
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? LinkTextView else { return }
        editor.onFocusChange = onFocusChange
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            editor.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LinkEditor
        init(_ parent: LinkEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? LinkTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
        }
    }
}
