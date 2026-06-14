#if os(macOS)
import SwiftUI
import AppKit

/// v1.1.0 (FF) · Phase 4 — the immersive reading page (全新阅读页).
///
/// Replaces the Phase-3 `MacReaderPlaceholder`. A full-window overlay (ZStack
/// top in `MacShellView`) that renders a `finalized` chapter for reading:
/// 宋体排版 + 三主题 (day/sepia/night, **whole-window** tint — night turns the
/// entire shell dark, not just the text column) + 字号 A−/A+ + 上一章/下一章.
///
/// Pixel-targets the handoff `LinoWriting.dc.html` READER block (52-high top
/// bar; max-720 body column with kicker → Songti 38 title → 书名·N字 → accent
/// rule → justified Songti body → · 本章完 · → prev/next cards).
///
/// Data: reads only `chapter.draftText` / `title` / `index` + book title; the
/// displayed chapter is fetched by id (so prev/next navigation works against
/// any finalized chapter, not just the one open in the editor). Zero new
/// backend. Theme + font-size persist via `@AppStorage`.
///
/// macOS-only.
struct ReaderView: View {
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var bookStore: BookStore
    @EnvironmentObject var chaptersStore: ChaptersStore
    @EnvironmentObject var chapterEditorStore: ChapterEditorStore
    @EnvironmentObject var environment: AppEnvironment

    /// Persisted across launches (handoff: 主题 + 字号存 @AppStorage).
    @AppStorage("reader.theme") private var themeRaw: String = ReadingTheme.day.rawValue
    @AppStorage("reader.fontSizeIndex") private var fontSizeIndex: Int = ReadingTheme.defaultFontSizeIndex

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
        bookStore.book?.title ?? appStore.currentBook?.title ?? ""
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
            body(for: chapter)
        }
        // Whole-window shell tint — the overlay fills the window and its opaque
        // background drives 整窗变色 (night = whole shell dark).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .task(id: appStore.readingChapterId) {
            await loadDisplayedChapter()
        }
    }

    // MARK: - Top bar (52-high thin glass strip)

    private var topBar: some View {
        HStack(spacing: 14) {
            // traffic-light placeholder (system buttons sit over this region)
            trafficLights

            Button {
                appStore.closeReader()
            } label: {
                Text("‹ 返回工作台")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { pointer($0) }

            Spacer(minLength: 8)

            Text("\(bookTitle) · 第 \(chapter?.index ?? 0) 章")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.26) // letter-spacing 0.02em ≈ 13 × 0.02
                .foregroundStyle(theme.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                themeSwatch(.day)
                themeSwatch(.sepia)
                themeSwatch(.night)

                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 4)

                fontStepButton(label: "A−", size: 13) {
                    fontSizeIndex = max(0, fontSizeIndex - 1)
                }
                fontStepButton(label: "A+", size: 16) {
                    fontSizeIndex = min(ReadingTheme.fontSizeLadder.count - 1, fontSizeIndex + 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        // blur(30) saturate(1.6) over a tinted plate.
        .background(
            theme.barBackground
                .background(.ultraThinMaterial)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 8) {
            Circle().fill(LWColor.hex(0xFF5F57)).frame(width: 12, height: 12)
            Circle().fill(LWColor.hex(0xFEBC2E)).frame(width: 12, height: 12)
            Circle().fill(LWColor.hex(0x28C840)).frame(width: 12, height: 12)
        }
        .opacity(0) // placeholder only; macOS draws the real window buttons here
    }

    private func themeSwatch(_ t: ReadingTheme) -> some View {
        let selected = (t == theme)
        return Button {
            themeRaw = t.rawValue
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.swatchFill)
                .frame(width: 30, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
                // selection ring: 0 0 0 2px {bg}, 0 0 0 4px {accent}
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.background, lineWidth: 2)
                        .padding(-1)
                        .opacity(selected ? 1 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .padding(-3)
                        .opacity(selected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .help(t.label)
        .onHover { pointer($0) }
    }

    private func fontStepButton(label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size))
                .foregroundStyle(theme.text)
                .frame(width: 30, height: 30)
                .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }

    // MARK: - Body column (max 720 centered, padding 78/40/140)

    @ViewBuilder
    private func body(for chapter: Chapter?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let chapter {
                    // chapter kicker (强调色, letter-spacing 0.32em)
                    Text("第 \(chapter.index) 章")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(13 * 0.32)
                        .foregroundStyle(theme.accent)
                        .padding(.bottom, 16)

                    // Songti 38 bold title
                    Text(chapter.title ?? "")
                        .font(LWFont.songti(38, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineSpacing(38 * 0.3) // line-height 1.3
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)

                    // 书名 · N 字 (secondary)
                    HStack(spacing: 12) {
                        Text(bookTitle)
                        Text("·").opacity(0.4)
                        Text("\(wordCount(chapter)) 字")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
                    .padding(.bottom, 4)

                    // accent short rule (44 × 3, opacity 0.5, margin 32/40)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(theme.accent.opacity(0.5))
                        .frame(width: 44, height: 3)
                        .padding(.top, 32)
                        .padding(.bottom, 40)

                    // justified Songti body
                    ReaderBodyText(
                        paragraphs: paragraphs(chapter.draftText ?? ""),
                        fontSize: fontSize,
                        textColor: theme.text
                    )

                    // · 本章完 ·
                    chapterEndMark
                        .padding(.top, 64)

                    // prev / next (60 high, finalized chapters only)
                    HStack(spacing: 12) {
                        navCard(
                            leading: true,
                            label: "‹ 上一章",
                            subtitle: prevChapter.map { "第\($0.index)章 \($0.title ?? "")" } ?? "已是开篇",
                            target: prevChapter
                        )
                        navCard(
                            leading: false,
                            label: "下一章 ›",
                            subtitle: nextChapter.map { "第\($0.index)章 \($0.title ?? "")" } ?? "敬请期待",
                            target: nextChapter
                        )
                    }
                    .padding(.top, 40)
                } else if isLoading {
                    ProgressView()
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 78)
            .padding(.bottom, 140)
        }
    }

    private var chapterEndMark: some View {
        HStack(spacing: 16) {
            Rectangle().fill(theme.hairline).frame(width: 40, height: 0.5)
            Text("· 本章完 ·")
                .font(LWFont.songti(15))
                .foregroundStyle(theme.secondary)
            Rectangle().fill(theme.hairline).frame(width: 40, height: 0.5)
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
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                Text(subtitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .padding(.horizontal, 18)
            .frame(height: 60)
            .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.6 : 1)
        .onHover { if target != nil { pointer($0) } }
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

// MARK: - Justified Songti body

/// Read-only justified body text. SwiftUI `Text` has no justified alignment and
/// no first-line indent, both of which the handoff reading body requires
/// (`text-align: justify; text-indent: 2em; line-height: 2.05`). Lay the text
/// out with `NSAttributedString` paragraph attributes — exact CJK parity —
/// inside a width-reading container that measures the laid-out height and gives
/// the SwiftUI column an explicit frame (an `NSTextView` reports no usable
/// intrinsic height by itself, which would otherwise collapse the column).
private struct ReaderBodyText: View {
    let paragraphs: [String]
    let fontSize: CGFloat
    let textColor: Color

    @State private var measuredHeight: CGFloat = 1

    private var attributed: NSAttributedString {
        let font = NSFont(name: LWFont.songtiFamily, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)

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
            .foregroundColor: NSColor(textColor),
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
        let text = attributed
        return GeometryReader { proxy in
            JustifiedTextRepresentable(
                attributed: text,
                width: proxy.size.width,
                height: $measuredHeight
            )
        }
        .frame(height: measuredHeight)
    }
}

/// `NSTextView` host. Pins the text container to the available `width`,
/// re-lays out, and reports the used height back to SwiftUI.
private struct JustifiedTextRepresentable: NSViewRepresentable {
    let attributed: NSAttributedString
    let width: CGFloat
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard width > 0 else { return }
        textView.textStorage?.setAttributedString(attributed)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.frame.size.width = width

        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        if abs(used - height) > 0.5 {
            DispatchQueue.main.async { height = used }
        }
    }
}
#endif
