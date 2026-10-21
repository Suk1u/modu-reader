//
//  TextPageView.swift
//  ModuReader
//
//  单页文字渲染视图。每个实例持有独立的 TextKit 2 栈，只渲染自己的字符区间。
//

import UIKit

/// 单页文字视图。
///
/// 设计要点：
/// - 只持有本页的 `NSAttributedString` 子串，不共享整章（内存可控）。
/// - 用 `NSTextViewportLayoutController` 驱动布局，`draw(_:)` 中逐 fragment 绘制。
/// - 不使用 `UITextView`：其封装过深，无法精确控制分页与 fragment 生命周期。
final class TextPageView: UIView {

    // MARK: - TextKit stack

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private var viewportController: NSTextViewportLayoutController?

    /// 本页对应的字符区间（章节内绝对偏移）。
    private(set) var pageRange: NSRange = NSRange(location: 0, length: 0)

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw

        // 禁用自动调整，由外部显式设置尺寸
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        contentStorage.addTextLayoutManager(layoutManager)

        let controller = NSTextViewportLayoutController(textLayoutManager: layoutManager)
        controller.delegate = self
        viewportController = controller
    }

    // MARK: - Configuration

    /// 配置本页内容。
    ///
    /// - Parameters:
    ///   - attributedText: 本章完整富文本（内部只取 `range` 部分）。
    ///   - range: 本页在章节中的字符区间。
    ///   - contentSize: 正文区域尺寸。
    func configure(
        chapterText: NSAttributedString,
        range: NSRange,
        contentSize: CGSize
    ) {
        let safeRange = Self.clamp(range, to: chapterText.length)
        pageRange = safeRange

        let pageText: NSAttributedString
        if safeRange.length > 0 {
            pageText = chapterText.attributedSubstring(from: safeRange)
        } else {
            pageText = NSAttributedString(string: "")
        }

        textContainer.size = contentSize
        contentStorage.attributedString = pageText

        // 分页后重新布局
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        viewportController?.layoutViewport()
        setNeedsDisplay()
    }

    /// 仅更新文字颜色（主题切换），不重新分页。
    func updateTextColor(_ color: UIColor) {
        guard contentStorage.attributedString.length > 0 else { return }
        let range = NSRange(location: 0, length: contentStorage.attributedString.length)
        let mutable = NSMutableAttributedString(attributedString: contentStorage.attributedString)
        mutable.addAttribute(.foregroundColor, value: color, range: range)
        contentStorage.attributedString = mutable
        setNeedsDisplay()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        viewportController?.layoutViewport()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard contentStorage.attributedString.length > 0 else { return }

        viewportController?.layoutViewport()

        layoutManager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            // 跳过完全在可视区外的 fragment
            guard frame.intersects(bounds) else { return true }

            context.saveGState()
            fragment.draw(at: frame.origin, in: context)
            context.restoreGState()
            return true
        }
    }

    // MARK: - Reuse

    /// 回收前清理内容，避免复用池持有大文本。
    func prepareForReuse() {
        pageRange = NSRange(location: 0, length: 0)
        contentStorage.attributedString = NSAttributedString(string: "")
        setNeedsDisplay()
    }

    // MARK: - Helpers

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = max(0, min(range.location, length))
        let maxLength = length - location
        let clampedLength = max(0, min(range.length, maxLength))
        return NSRange(location: location, length: clampedLength)
    }
}

// MARK: - NSTextViewportLayoutControllerDelegate

extension TextPageView: NSTextViewportLayoutControllerDelegate {

    func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        bounds
    }

    func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        // 本视图在 draw(_:) 中直接绘制 fragment，不维护额外的渲染表面。
        // 这里刻意不做任何事：在此调用 setNeedsDisplay() 会形成
        // layoutViewport → configure → setNeedsDisplay → draw → layoutViewport 的重绘循环。
    }
}
