import SwiftUI
import SessionKit
import UIKit

/// The existing source reader sheet, with one selectable chapter and an initial sentence scroll.
struct NativeTextPeekView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Chosen by `PlaybackTextReaderTarget.resolve`, the same rule as the More sheet's Text button (#1547).
    let target: PlaybackTextReaderTarget

    static let sheetIdentifier = "nativeText.peek.sheet"
    static let textIdentifier = "nativeText.peek.text"

    private var reader: PlaybackLivePassage.Reader { target.reader }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(reader.chapterTitle ?? "Full Text").font(.headline)
                if !reader.text.isEmpty {
                    NativeTextReader(reader: reader)
                        // Set at the SwiftUI layer too: an identifier on an ancestor replaces the
                        // UITextView's own, so the child must state its identifier explicitly.
                        .accessibilityIdentifier(NativeTextPeekView.textIdentifier)
                } else {
                    Text("No native text is available.")
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(20)
            .navigationTitle(title.isEmpty ? "Source Text" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            // Contain the children so the sheet's identifier labels this container
            // instead of being pushed down onto the text view.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(NativeTextPeekView.sheetIdentifier)
        }
    }
}

private struct NativeTextReader: UIViewRepresentable {
    let reader: PlaybackLivePassage.Reader
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> NativeTextReaderView { NativeTextReaderView() }

    func updateUIView(_ view: NativeTextReaderView, context: Context) {
        // Reading the environment makes Dynamic Type changes update the UIKit font too.
        _ = dynamicTypeSize
        view.display(reader, font: .preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection))
    }
}

/// Uses one text storage so selection can cross sentence and paragraph boundaries.
final class NativeTextReaderView: UITextView {
    private var displayedReader: PlaybackLivePassage.Reader?
    private var displayedFont: UIFont?
    private var pendingInitialRange: NSRange?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        adjustsFontForContentSizeCategory = true
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 16, right: 0)
        accessibilityIdentifier = NativeTextPeekView.textIdentifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ reader: PlaybackLivePassage.Reader, font: UIFont) {
        let changedDocument = displayedReader != reader
        guard changedDocument || displayedFont != font else { return }
        let previousSelection = selectedRange
        let previousOffset = contentOffset
        displayedReader = reader
        displayedFont = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let content = NSMutableAttributedString(string: reader.text, attributes: [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph
        ])
        if let range = reader.currentSentenceRange, range.length > 0 {
            content.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.22), range: range)
        }
        attributedText = content
        if changedDocument {
            pendingInitialRange = reader.currentSentenceRange
            setContentOffset(.zero, animated: false)
        } else {
            // A font update may relayout the chapter, but must not replace the user's selection.
            selectedRange = previousSelection
            setContentOffset(previousOffset, animated: false)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let range = pendingInitialRange else { return }
        pendingInitialRange = nil
        if let manager = textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
        } else {
            layoutManager.ensureLayout(for: textContainer)
        }
        // A long sentence may exceed the viewport at accessibility text sizes.
        // Reveal its beginning while retaining the highlight over the entire sentence.
        scrollRangeToVisible(NSRange(location: range.location, length: min(1, range.length)))
    }
}
