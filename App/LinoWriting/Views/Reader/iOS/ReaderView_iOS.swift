#if os(iOS)
import SwiftUI
import UIKit

/// v1.2.0 (GG, P5) — the iPhone immersive reading page (全新阅读页).
///
/// Rendered as a `.fullScreenCover` over the navigation stack (mounted in
/// `RootViewIOS`, driven by `appStore.readingChapterId`). Reads a `finalized`
/// chapter for reading: 宋体排版 + three reading themes (day/sepia/night, a
/// **whole-screen** tint — night turns the entire shell dark + the status-bar
/// icons white, not just the text column) + 字号 A−/A+ + 上一章/下一章.
///
/// Pixel-targets the iOS handoff (`LinoWriting iOS.dc.html` Reader block /
/// README §4): a thin glass top bar (54px status-bar inset + ‹ 完成 chip +
/// centred 书名 · 第 N 章 + three 26×26 theme swatches with selection ring +
/// A−/A+) over a body column (kicker → Songti 30 title → 书名·N字 → accent
/// short rule → **justified Songti body** → · 本章完 · → prev/next cards, all
/// finalized chapters only).
///
/// Data: reads only `chapter.draftText` / `title` / `index` + book title; the
/// displayed chapter is fetched by id (so prev/next navigation works against
/// any finalized chapter, not just the one open in the editor). Zero new
/// backend. Theme + font-size persist via **iOS-independent** `@AppStorage`
/// keys (`reader.ios.*`) so the iPhone sheet never collides with the macOS
/// window's `reader.*` keys.
///
/// **iOS justified body** (handoff `text-align: justify; text-indent: 2em;
/// line-height: 2.05`): SwiftUI `Text` has neither justified alignment nor a
/// first-line indent, so the body is laid out by a `UITextView`
/// (`UIViewRepresentable`) with `NSAttributedString` paragraph attributes —
/// exact CJK parity. macOS uses `NSTextView`; iOS needs the UIKit equivalent.
///
/// iOS-only — macOS routes through `MacShellView`'s `ReaderView`, untouched.
struct ReaderView_iOS: View {
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var environment: AppEnvironment

    /// Persisted across launches — **iOS-independent keys** (≠ macOS `reader.*`).
    @AppStorage("reader.ios.theme") private var themeRaw: String = ReadingTheme.day.rawValue
    @AppStorage("reader.ios.fontSizeIndex") private var fontSizeIndex: Int = ReadingTheme.defaultFontSizeIndex

    /// The full chapter currently on screen (with `draftText`). Loaded by id;
    /// re-loaded on prev/next so any finalized chapter can be read.
    @State private var chapter: Chapter?
    @State private var isLoading = false

    private var theme: ReadingTheme {
        ReadingTheme(rawValue: themeRaw) ?? .day
    }

    private var fontSize: CGFloat {
        let ladder = ReadingTheme.fontSizeLadder
        let i = min(max(fontSizeIndex, 0), ladder.count - 1)
        return ladder[i]
    }

    private var bookTitle: String {
        appStore.currentBook?.title ?? ""
    }

    /// Only finalized chapters, ordered — prev/next navigates within these.
    private var finalizedChapters: [ChapterSummary] {
        chaptersStore.sorted.filter { $0.status == .finalized }
    }

    private var currentFinalizedIndex: Int? {
        guard let id = chapter?.id else { return nil }
        return finalizedChapters.firstIndex { $0.id == id }
    }

    private var prevChapter: ChapterSummary? {
        guard let i = currentFinalizedIndex, i > 0 else { return nil }
        return finalizedChapters[i - 1]
    }

    private var nextChapter: ChapterSummary? {
        guard let i = currentFinalizedIndex, i < finalizedChapters.count - 1 else { return nil }
        return finalizedChapters[i + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            bodyColumn
        }
        // Whole-screen shell tint — the fullScreenCover fills the screen and its
        // opaque background drives 整屏变色 (night = whole shell dark).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        // 夜间整机壳层 + 状态栏图标转白 (handoff: statusFg flips to #fff for night).
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task(id: appStore.readingChapterId) {
            await loadDisplayedChapter()
        }
    }

    // MARK: - Top bar (thin glass strip, 54px status-bar inset)

    private var topBar: some View {
        HStack(spacing: 10) {
            // ‹ 完成 chip — exits the reader.
            Button {
                appStore.closeReader()
            } label: {
                Text("‹ 完成")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text)
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .frame(height: 34)
                    .background(theme.chipBackground, in: Capsule())
            }
            .buttonStyle(.plain)

            // 书名 · 第 N 章 (centred, ellipsised).
            Text("\(bookTitle) · \(chapterLabel)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                themeSwatch(.day)
                themeSwatch(.sepia)
                themeSwatch(.night)

                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 3)

                fontStepButton(label: "A−", size: 12) {
                    fontSizeIndex = max(0, fontSizeIndex - 1)
                }
                fontStepButton(label: "A+", size: 15) {
                    fontSizeIndex = min(ReadingTheme.fontSizeLadder.count - 1, fontSizeIndex + 1)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        // blur(24) saturate(1.6) over a tinted plate. The status-bar inset is
        // handled by SwiftUI's safe area (the bar content sits below the notch);
        // the glass plate extends up behind the status bar via `ignoresSafeArea`.
        .background(
            theme.barBackground
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
    }

    private func themeSwatch(_ t: ReadingTheme) -> some View {
        let selected = (t == theme)
        return Button {
            themeRaw = t.rawValue
        } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(t.swatchFill)
                .frame(width: 26, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
                // selection ring: 0 0 0 2px {bg}, 0 0 0 4px {accent}
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(theme.background, lineWidth: 2)
                        .padding(-1)
                        .opacity(selected ? 1 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .padding(-3)
                        .opacity(selected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private func fontStepButton(label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size))
                .foregroundStyle(theme.text)
                .frame(width: 28, height: 28)
                .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body column (padding 40/26/120)

    @ViewBuilder
    private var bodyColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let chapter {
                    // chapter kicker (强调色, letter-spacing 0.3em)
                    Text(chapterLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(12 * 0.3)
                        .foregroundStyle(theme.accent)
                        .padding(.bottom, 14)

                    // Songti 30 bold title
                    Text(chapter.title?.nonEmptyOr("未命名") ?? "未命名")
                        .font(LWFont.songti(30, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineSpacing(30 * 0.32) // line-height 1.32
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)

                    // 书名 · N 字 (secondary)
                    HStack(spacing: 10) {
                        Text(bookTitle).fixedSize()
                        Text("·").opacity(0.4)
                        Text("\(wordCount(chapter)) 字").fixedSize()
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondary)

                    // accent short rule (40 × 3, opacity 0.5, margin 26/32)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(theme.accent.opacity(0.5))
                        .frame(width: 40, height: 3)
                        .padding(.top, 26)
                        .padding(.bottom, 32)

                    // justified Songti body (UITextView)
                    JustifiedReaderBody(
                        paragraphs: paragraphs(chapter.draftText ?? ""),
                        fontSize: fontSize,
                        textColor: theme.text
                    )

                    // · 本章完 ·
                    chapterEndMark
                        .padding(.top, 52)

                    // prev / next (58 high min, finalized chapters only)
                    HStack(spacing: 10) {
                        navCard(
                            leading: true,
                            label: "‹ 上一章",
                            subtitle: prevChapter.map { "第\($0.index)章 \($0.title?.nonEmptyOr("未命名") ?? "未命名")" } ?? "已是开篇",
                            target: prevChapter
                        )
                        navCard(
                            leading: false,
                            label: "下一章 ›",
                            subtitle: nextChapter.map { "第\($0.index)章 \($0.title?.nonEmptyOr("未命名") ?? "未命名")" } ?? "敬请期待",
                            target: nextChapter
                        )
                    }
                    .padding(.top, 32)
                } else if isLoading {
                    ProgressView()
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 40)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
    }

    private var chapterEndMark: some View {
        HStack(spacing: 14) {
            Rectangle().fill(theme.hairline).frame(width: 36, height: 0.5)
            Text("· 本章完 ·")
                .font(LWFont.songti(14))
                .foregroundStyle(theme.secondary)
            Rectangle().fill(theme.hairline).frame(width: 36, height: 0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private func navCard(leading: Bool, label: String, subtitle: String, target: ChapterSummary?) -> some View {
        Button {
            guard let target else { return }
            appStore.openReader(chapterId: target.id)
        } label: {
            VStack(alignment: leading ? .leading : .trailing, spacing: 3) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 58)
            .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.55 : 1)
    }

    // MARK: - Data

    /// Fetch the displayed chapter for `appStore.readingChapterId`. Reuses the
    /// editor's already-loaded chapter when it matches (no redundant GET); else
    /// fetches by id via the shared API client.
    private func loadDisplayedChapter() async {
        guard let id = appStore.readingChapterId else { return }
        if let editorChapter = chapterEditorStore.chapter, editorChapter.id == id {
            chapter = editorChapter
            return
        }
        if chapter?.id == id { return }
        isLoading = true
        defer { isLoading = false }
        do {
            chapter = try await environment.apiClient.getChapter(id: id)
        } catch {
            // Leave the previous chapter on screen; the workspace error bus
            // already surfaces fetch failures as a Toast.
        }
    }

    // MARK: - Helpers

    private var chapterLabel: String {
        guard let chapter else { return "" }
        return "第 \(chapter.index) 章"
    }

    private func paragraphs(_ text: String) -> [String] {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Handoff word count: strip all whitespace, count remaining characters.
    private func wordCount(_ chapter: Chapter) -> Int {
        let body = chapter.draftText ?? ""
        return body.filter { !$0.isWhitespace }.count
    }
}

// MARK: - Justified Songti body (UITextView)

/// Read-only justified body text. SwiftUI `Text` has no justified alignment and
/// no first-line indent, both of which the handoff reading body requires
/// (`text-align: justify; text-indent: 2em; line-height: 2.05`). Lay the text
/// out with `NSAttributedString` paragraph attributes — exact CJK parity —
/// inside a width-reading container that measures the laid-out height and gives
/// the SwiftUI column an explicit frame (a non-scrolling `UITextView` otherwise
/// reports no usable height in a vertical `ScrollView`, collapsing the column).
private struct JustifiedReaderBody: View {
    let paragraphs: [String]
    let fontSize: CGFloat
    let textColor: Color

    private var attributed: NSAttributedString {
        let font = UIFont(name: LWFont.songtiFamily, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize)

        let para = NSMutableParagraphStyle()
        para.alignment = .justified
        // line-height 2.05 → multiple of the font's natural line height.
        para.lineHeightMultiple = 2.05
        // text-indent: 2em → first line indented by two font sizes.
        para.firstLineHeadIndent = fontSize * 2
        // margin: 0 0 1.5em → paragraph spacing.
        para.paragraphSpacing = fontSize * 1.5
        para.baseWritingDirection = .leftToRight

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(textColor),
            .paragraphStyle: para
        ]

        let result = NSMutableAttributedString()
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: p, attributes: attrs))
        }
        return result
    }

    var body: some View {
        // The modern `UIViewRepresentable.sizeThatFits` API lets the text view
        // report its own height for the SwiftUI-proposed width, so the body sizes
        // correctly inside the vertical ScrollView (no GeometryReader — it
        // reported an unbounded width here, overflowing the column + breaking
        // justification).
        JustifiedTextRepresentable(attributed: attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `UITextView` host. Non-scrolling (lives inside the SwiftUI ScrollView); sizes
/// itself to the SwiftUI-proposed width via `sizeThatFits`, so justified CJK
/// text breaks against the real reading column and the body reports the right
/// height.
private struct JustifiedTextRepresentable: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.attributedText != attributed {
            textView.attributedText = attributed
        }
    }

    /// iOS 16+ representable sizing: report the laid-out height for the width
    /// SwiftUI proposes (the column). This is the deterministic, race-free way to
    /// size a UIView inside SwiftUI and pins the justification width.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }
}
#endif
