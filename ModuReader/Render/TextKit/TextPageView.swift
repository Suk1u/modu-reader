//
//  TextPageView.swift
//  ModuReader
//
//  单页文字视图。
//
//  渲染方式：从共享的 `ChapterLayout` 里按 Y 区间绘制。
//  分页与渲染读的是同一份排版结果，几何完全一致。
//

import UIKit

/// 单页文字视图。
@MainActor
final class TextPageView: UIView {

    /// 共享的整章排版。由引擎注入，多页共用同一实例。
    private weak var layout: ChapterLayout?

    /// 本页对应的字符区间。
    private(set) var pageRange: NSRange = NSRange(location: 0, length: 0)

    /// 本页首行的绝对 Y。
    private var pageY: CGFloat = 0

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
    ///   - slice: 本页区间与 Y 偏移。
    func configure(layout: ChapterLayout, slice: PageSlice) {
        self.layout = layout
        self.pageRange = slice.range
        self.pageY = slice.yOffset
        setNeedsDisplay()
    }

    /// 主题色变化后重绘。
    func refresh() {
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard let layout, layout.isReady else { return }

        layout.draw(in: context, pageY: pageY, pageHeight: bounds.height)
    }

    // MARK: - Reuse

    /// 回收前清理。
    func prepareForReuse() {
        pageRange = NSRange(location: 0, length: 0)
        pageY = 0
        layout = nil
        setNeedsDisplay()
    }
}
