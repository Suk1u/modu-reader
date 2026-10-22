//
//  TextPageView.swift
//  ModuReader
//
//  单页文字视图。用 TextKit 2 渲染。
//
//  定位方式：按「页首字符位置」找到对应 fragment，
//  以它的 Y 作为绘制原点。不依赖分页阶段算出的 Y 坐标 ——
//  分页用 CTFramesetter、渲染用 TextKit 2，两者的 Y 坐标体系不同，
//  但字符位置是共享且稳定的锚点。
//

import UIKit

/// 单页文字视图。
@MainActor
final class TextPageView: UIView {

    /// 共享的整章排版。
    private weak var layout: ChapterLayout?

    /// 本页对应的字符区间。
    private(set) var pageRange: NSRange = NSRange(location: 0, length: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true
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

    /// 配置本页。
    ///
    /// - Parameters:
    ///   - layout: 整章排版（共享）。
    ///   - slice: 本页区间。
    func configure(layout: ChapterLayout, slice: PageSlice) {
        self.layout = layout
        self.pageRange = slice.range
        setNeedsDisplay()
    }

    /// 主题色变化后重绘。
    func refresh() {
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard let layout, layout.isReady, pageRange.length > 0 else { return }

        layout.drawPage(
            in: context,
            range: pageRange,
            pageHeight: bounds.height
        )
    }

    // MARK: - Reuse

    /// 回收前清理。
    func prepareForReuse() {
        pageRange = NSRange(location: 0, length: 0)
        layout = nil
        setNeedsDisplay()
    }
}
