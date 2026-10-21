//
//  TextPageView.swift
//  ModuReader
//
//  单页文字视图。用 TextKit 2 渲染。
//
//  渲染策略：按「页首字符位置」定位到对应 fragment，从那里开始绘制。
//
//  为什么不按 Y 坐标平移：
//  TextKit 2 的 fragment 坐标在超大容器下不可靠（实测 10 万字章节
//  的 Y 累加到 19525，与内容高度不符）。字符位置是唯一稳定可靠的锚点。
//
//  为什么不按页切片重新排版：
//  切片会让每页首段丢段前距、末段丢段后距，跨页段落的缩进与
//  列表编号也会重算，导致翻页时行距跳动。
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

    /// 当前排版宽度。
    private var layoutWidth: CGFloat = 0

    /// 容器高度上限。仅用于让 TextKit 知道这是「无界」容器；
    /// 实际布局由 viewport 按需推进。
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
    ///   - slice: 本页区间。
    ///   - contentSize: 正文区域尺寸。
    func configure(
        chapterText: NSAttributedString,
        slice: PageSlice,
        contentSize: CGSize
    ) {
        pageRange = Self.clamp(slice.range, to: chapterText.length)

        let width = max(1, contentSize.width)

        if layoutWidth != width || contentStorage.attributedString == nil {
            layoutWidth = width
            textContainer.size = CGSize(width: width, height: Self.layoutHeightLimit)
            contentStorage.attributedString = chapterText
            layoutManager.invalidateLayout(for: contentStorage.documentRange)
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
        guard let text = contentStorage.attributedString, text.length > 0 else { return }
        guard pageRange.length > 0 else { return }

        // 定位本页首字符对应的排版位置
        guard let startLocation = contentStorage.location(
            contentStorage.documentRange.location,
            offsetBy: pageRange.location
        ) else {
            return
        }

        // 只布局本页需要的范围：从页首到页尾。
        // 这是 TextKit 2 的按需布局 —— 不会排完整章。
        let endOffset = min(text.length, pageRange.location + pageRange.length)
        if let endLocation = contentStorage.location(
            contentStorage.documentRange.location,
            offsetBy: endOffset
        ), let pageTextRange = NSTextRange(location: startLocation, end: endLocation) {
            layoutManager.ensureLayout(for: pageTextRange)
        }

        // 找到本页第一个 fragment，以它的位置为绘制原点。
        // 这样无需知道整章排版结果的绝对 Y 坐标。
        guard let firstFragment = layoutManager.textLayoutFragment(for: startLocation) else {
            return
        }
        let originY = firstFragment.layoutFragmentFrame.minY

        // 把整章排版结果平移到「本页首行在 y=0」，
        // 只绘制落在本页高度内的 fragment。
        context.saveGState()
        context.translateBy(x: 0, y: -originY)

        let visibleBottom = originY + bounds.height

        layoutManager.enumerateTextLayoutFragments(
            from: startLocation,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame

            if frame.maxY < originY { return true }
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
