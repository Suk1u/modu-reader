//
//  ChapterLayout.swift
//  ModuReader
//
//  整章排版结果。分页与渲染共用同一份，保证几何完全一致。
//
//  为什么必须共享：
//  之前分页用 CTFramesetter、渲染用 TextKit 2，两者虽同源 CoreText，
//  但对段落间距、首行缩进、attachment 高度的解释有细微差异，
//  累积到几十行就会产生半行偏移 —— 表现为空白页、文字错位、
//  进度记录不准。
//
//  共享同一份 NSTextLayoutManager 后，分页读到的 Y 坐标
//  就是渲染用的 Y 坐标，不存在任何偏差。
//

import UIKit

/// 整章排版结果。
///
/// 线程约束：`@MainActor`。TextKit 对象不跨线程。
/// 后台分页使用独立的临时栈（见 `Paginator`），不复用本对象。
@MainActor
final class ChapterLayout {

    /// 容器高度上限。
    ///
    /// 取有限值而非 `.greatestFiniteMagnitude`：后者会触发浮点溢出。
    ///
    /// 计算依据：12,000 字上限 × 每行约 40 字 = 300 行，
    /// 行高 19pt × 1.8 = 34pt，总计约 10,200pt。
    /// 取 100,000pt 留出 10 倍余量，覆盖大字号（32pt）与窄屏（每行 20 字）：
    /// 12,000 / 20 = 600 行 × 32 × 2.4 = 46,080pt，仍在范围内。
    private static let heightLimit: CGFloat = 100_000

    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)

    /// 当前排版使用的宽度。宽度变化时必须重建。
    private(set) var width: CGFloat = 0

    /// 是否已完成排版。
    private(set) var isReady = false

    /// 排版结果的整体高度。
    private(set) var contentHeight: CGFloat = 0

    init() {
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.textContainer = textContainer
        layoutManager.usesFontLeading = true
        layoutManager.usesHyphenation = false
        contentStorage.addTextLayoutManager(layoutManager)
    }

    /// 准备排版。
    ///
    /// 只灌入文本并设置容器宽度，**不做全量布局**。
    /// 真正的布局由 `drawPage` 按页触发（TextKit 2 的按需布局）。
    ///
    /// - Parameters:
    ///   - attributed: 整章富文本。
    ///   - width: 正文可用宽度（已扣除左右内边距）。
    /// - Returns: 是否发生了重建。
    @discardableResult
    func prepare(attributed: NSAttributedString, width: CGFloat) -> Bool {
        let targetWidth = max(1, width)
        guard !isReady || self.width != targetWidth else { return false }

        self.width = targetWidth
        textContainer.size = CGSize(width: targetWidth, height: Self.heightLimit)
        contentStorage.attributedString = attributed
        layoutManager.invalidateLayout(for: contentStorage.documentRange)

        // 只布局第一屏，拿到起始几何即可。
        // 后续页由 drawPage 按需布局。
        let probeRange = NSTextRange(
            location: contentStorage.documentRange.location,
            end: contentStorage.location(
                contentStorage.documentRange.location,
                offsetBy: min(500, attributed.length)
            )
        )
        if let probeRange {
            layoutManager.ensureLayout(for: probeRange)
        }

        isReady = true
        contentHeight = 0
        return true
    }

    /// 绘制指定字符区间对应的那一页。
    ///
    /// 做法：按区间首字符定位到 fragment，以它的 Y 作为绘制原点，
    /// 只画落在 `pageHeight` 高度内的 fragment。
    ///
    /// - Parameters:
    ///   - context: 绘制上下文。
    ///   - range: 本页的字符区间。
    ///   - pageHeight: 页高。
    func drawPage(in context: CGContext, range: NSRange, pageHeight: CGFloat) {
        guard isReady else { return }
        guard range.length > 0 else { return }

        guard let startLocation = contentStorage.location(
            contentStorage.documentRange.location,
            offsetBy: range.location
        ) else { return }

        // 只布局本页范围，避免整章排版（TextKit 2 按需布局）
        let endOffset = min(
            contentStorage.attributedString?.length ?? 0,
            range.location + range.length
        )
        if let endLocation = contentStorage.location(
            contentStorage.documentRange.location,
            offsetBy: endOffset
        ), let pageRange = NSTextRange(location: startLocation, end: endLocation) {
            layoutManager.ensureLayout(for: pageRange)
        }

        // 以本页首字符所在 fragment 的 Y 为原点
        guard let firstFragment = layoutManager.textLayoutFragment(for: startLocation) else {
            return
        }
        let originY = firstFragment.layoutFragmentFrame.minY

        context.saveGState()
        context.translateBy(x: 0, y: -originY)

        let visibleBottom = originY + pageHeight

        layoutManager.enumerateTextLayoutFragments(
            from: startLocation,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame

            if frame.maxY <= originY { return true }
            if frame.minY >= visibleBottom { return false }

            fragment.draw(at: frame.origin, in: context)
            return true
        }

        context.restoreGState()
    }

    /// 完成整章排版并计算总高度（滚动模式用）。
    ///
    /// 与 `prepare` 的区别：这里会真正排完整章，
    /// 因为滚动模式需要知道内容总高度才能设置 scrollView 的 contentSize。
    @discardableResult
    func prepareFull(attributed: NSAttributedString, width: CGFloat) -> Bool {
        prepare(attributed: attributed, width: width)
        guard isReady else { return false }

        layoutManager.ensureLayout(for: contentStorage.documentRange)

        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        contentHeight = maxY
        return true
    }

    /// 绘制整章（滚动模式用）。
    func drawAll(in context: CGContext) {
        guard isReady else { return }
        context.saveGState()
        layoutManager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
        context.restoreGState()
    }

    /// 更新文字颜色。
    func updateTextColor(_ color: UIColor) {
        guard let current = contentStorage.attributedString, current.length > 0 else { return }
        let mutable = NSMutableAttributedString(attributedString: current)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: color, range: full)
        contentStorage.attributedString = mutable
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
        isReady = true
    }

    /// 清空。
    func reset() {
        contentStorage.attributedString = NSAttributedString(string: "")
        isReady = false
        width = 0
        contentHeight = 0
    }
}
