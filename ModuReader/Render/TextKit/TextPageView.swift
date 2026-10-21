//
//  TextPageView.swift
//  ModuReader
//
//  单页文字渲染视图。
//
//  渲染策略：用 CoreText 直接绘制「章节全文 + 本页可见区间」。
//  这与 Paginator 使用同一套 CoreText 断行引擎，因此分页边界与渲染完全一致。
//
//  为什么不用 TextKit 2 渲染：
//  - 分页已经用 CTFramesetter 算好，渲染若换用 TextKit 2 会引入第二套断行规则，
//    可能出现「分页说这行在这页，渲染却把它挤到下一页」的错位。
//  - 单页 CoreText 绘制足够快（一页通常 20~30 行），且内存占用极低。
//  - 后续做选词/标注时，可以再引入 TextKit 2 的交互层，不影响分页。
//

import UIKit
import CoreText

/// 单页文字视图。
@MainActor
final class TextPageView: UIView {

    /// 本页对应的字符区间（章节内绝对偏移）。
    private(set) var pageRange: NSRange = NSRange(location: 0, length: 0)

    /// 本页要绘制的富文本（整章）。
    private var chapterText: NSAttributedString?
    /// 页面内边距已由调用方扣除，这里绘制区域就是 bounds。
    private var contentSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 不用 UIScreen.main：iPad 分屏 / 台前调度下它不可靠
        layer.contentsScale = traitCollection.displayScale
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.displayScale != previousTraitCollection?.displayScale {
            layer.contentsScale = traitCollection.displayScale
            setNeedsDisplay()
        }
    }

    // MARK: - Configuration

    /// 配置本页内容。
    ///
    /// - Parameters:
    ///   - chapterText: 本章完整富文本。
    ///   - range: 本页在章节中的字符区间。
    ///   - contentSize: 正文区域尺寸。
    func configure(
        chapterText: NSAttributedString,
        range: NSRange,
        contentSize: CGSize
    ) {
        self.chapterText = chapterText
        self.pageRange = Self.clamp(range, to: chapterText.length)
        self.contentSize = contentSize
        setNeedsDisplay()
    }

    /// 仅更新文字颜色（主题切换），不重新分页。
    func updateTextColor(_ color: UIColor) {
        guard let chapterText else { return }
        let mutable = NSMutableAttributedString(attributedString: chapterText)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: color, range: full)
        self.chapterText = mutable
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard let chapterText, pageRange.length > 0 else { return }
        guard contentSize.width > 1, contentSize.height > 1 else { return }

        // 分页时用的矩形与这里必须完全一致
        let pageRect = CGRect(origin: .zero, size: contentSize)

        // 只对「从本页起点到章节结尾」建 framesetter，
        // 这样第一页就是本页内容，无需再做偏移裁剪。
        let start = pageRange.location
        let remainingLength = chapterText.length - start
        guard remainingLength > 0 else { return }

        let remaining = chapterText.attributedSubstring(
            from: NSRange(location: start, length: remainingLength)
        )

        let framesetter = CTFramesetterCreateWithAttributedString(
            remaining as CFAttributedString
        )
        let path = CGPath(rect: pageRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )

        // CoreText 使用左下原点，UIKit 上下文是左上原点
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        CTFrameDraw(frame, context)

        context.restoreGState()
    }

    // MARK: - Reuse

    /// 回收前清理内容，避免复用池持有大文本。
    func prepareForReuse() {
        pageRange = NSRange(location: 0, length: 0)
        chapterText = nil
        contentSize = .zero
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
