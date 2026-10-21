//
//  TextPageView.swift
//  ModuReader
//
//  单页文字视图。用 TextKit 2 渲染，与 Paginator 共用同一套排版引擎。
//
//  渲染策略：
//  1. 整章文本灌入独立的 NSTextContentStorage
//  2. 用与分页时完全相同的容器宽度排版（高度无限）
//  3. 把排版结果整体上移 slice.yOffset，只露出本页那一屏
//
//  为什么「整章排版 + 平移」而不是「按页切片重新排版」：
//  - 切片重新排版会让每页首段丢失段前距，末段丢失段后距，行距不一致
//  - 跨页的段落缩进、列表编号会重新计算，出现错位
//  - 图片等 attachment 在切片时会丢失上下文
//  整章排版一次，分页只做区间划分，渲染只做平移 —— 三处结果必然一致。
//

import UIKit

/// 单页文字视图。
@MainActor
final class TextPageView: UIView {

    // MARK: - TextKit stack

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)

    /// 本页对应的字符区间。
    private(set) var pageRange: NSRange = NSRange(location: 0, length: 0)

    /// 本页首行在整章排版中的 Y 偏移。
    private var pageYOffset: CGFloat = 0

    /// 当前使用的容器宽度，用于判断是否需要重建排版。
    private var layoutWidth: CGFloat = 0

    /// 排版容器的极大高度，与 Paginator 保持一致。
    private static let layoutHeightLimit: CGFloat = 10_000_000

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
        clipsToBounds = true

        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.textContainer = textContainer
        contentStorage.addTextLayoutManager(layoutManager)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
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
    ///   - chapterText: 本章完整富文本（含图片 attachment）。
    ///   - slice: 本页的区间与 Y 偏移。
    ///   - contentSize: 正文区域尺寸。
    func configure(
        chapterText: NSAttributedString,
        slice: PageSlice,
        contentSize: CGSize
    ) {
        let safeRange = Self.clamp(slice.range, to: chapterText.length)
        pageRange = safeRange
        pageYOffset = slice.yOffset

        let width = max(1, contentSize.width)

        // 只在宽度变化时重新灌文本与排版。
        // 同一章翻页时宽度不变，这里直接复用已有排版结果，翻页开销接近零。
        if layoutWidth != width || contentStorage.attributedString == nil {
            layoutWidth = width
            textContainer.size = CGSize(width: width, height: Self.layoutHeightLimit)
            contentStorage.attributedString = chapterText
            // 不调 ensureLayout(documentRange)：那会排完整个章节。
            // TextKit 在 enumerateTextLayoutFragments / draw 时会按需布局。
        }

        setNeedsDisplay()
    }

    /// 仅更新文字颜色（主题切换），不重新分页。
    func updateTextColor(_ color: UIColor) {
        guard let current = contentStorage.attributedString, current.length > 0 else { return }
        let mutable = NSMutableAttributedString(attributedString: current)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: color, range: full)
        contentStorage.attributedString = mutable
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard contentStorage.attributedString?.length ?? 0 > 0 else { return }

        // 把整章排版结果上移 pageYOffset，只绘制本页那一屏。
        //
        // TextKit 2 的 fragment 坐标是「文档坐标系」（左上原点、向下为正），
        // UIKit 的绘制上下文也是左上原点，因此直接平移即可，无需翻转。
        context.saveGState()
        context.translateBy(x: 0, y: -pageYOffset)

        let visibleBottom = pageYOffset + bounds.height

        // 从本页首字符的位置开始枚举，而不是从文档开头。
        // 长章节（10 万字）从 nil 开始会遍历前面所有 fragment，
        // 每帧都做一遍会明显拖慢翻页。
        let startLocation: (any NSTextLocation)? = {
            guard pageRange.location > 0,
                  let location = contentStorage.location(
                    contentStorage.documentRange.location,
                    offsetBy: pageRange.location
                  ) else {
                return contentStorage.documentRange.location
            }
            return location
        }()

        layoutManager.enumerateTextLayoutFragments(
            from: startLocation,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame

            // 在可视区上方（因起点略有回退）的 fragment 跳过绘制
            if frame.maxY < pageYOffset { return true }
            // 超出可视区底部 → 停止枚举
            if frame.minY > visibleBottom { return false }

            fragment.draw(at: frame.origin, in: context)
            return true
        }

        context.restoreGState()
    }

    // MARK: - Reuse

    /// 回收前清理内容，避免复用池持有大文本与图片。
    func prepareForReuse() {
        pageRange = NSRange(location: 0, length: 0)
        pageYOffset = 0
        layoutWidth = 0
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
