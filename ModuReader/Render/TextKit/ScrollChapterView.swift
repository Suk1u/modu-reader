//
//  ScrollChapterView.swift
//  ModuReader
//
//  滚动阅读的正文视图。整章排版一次性绘制在一块可滚动画布上。
//
//  与分页模式的差异：
//  - 分页：每页一个视图，只画本页 Y 区间
//  - 滚动：一个视图画整章，外层 UIScrollView 负责滚动
//
//  两者共用同一个 `ChapterLayout`，行几何完全一致，
//  切换模式时阅读位置不会漂移。
//

import UIKit

/// 滚动模式的正文画布。
@MainActor
final class ScrollChapterView: UIView {

    private var layout: ChapterLayout?

    /// 正文可用宽度（已扣除左右边距）。
    private var contentWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layer.contentsScale = traitCollection.displayScale
    }

    /// 配置整章内容。
    ///
    /// - Parameters:
    ///   - layout: 已完成整章排版的布局对象。
    ///   - contentWidth: 正文宽度。
    func configure(layout: ChapterLayout, contentWidth: CGFloat) {
        self.layout = layout
        self.contentWidth = contentWidth
        frame.size = CGSize(
            width: max(1, contentWidth),
            height: max(1, layout.contentHeight)
        )
        setNeedsDisplay()
    }

    /// 主题色变化后重绘。
    func refresh() {
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard let layout else { return }
        layout.drawAll(in: context)
    }
}