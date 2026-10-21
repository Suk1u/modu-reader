//
//  PagePool.swift
//  ModuReader
//
//  页面视图复用池。维持当前页与前后页，避免频繁创建销毁 TextKit 栈。
//

import UIKit

/// 页面视图池。
///
/// 容量固定为 `capacity`（默认 3：上一页 / 当前页 / 下一页）。
/// 超出容量的视图被移出视图层级并进入复用队列。
@MainActor
final class PagePool {

    /// 池容量。
    let capacity: Int

    /// 正在使用的视图，键为相对页号（-1 / 0 / 1）。
    private var activeViews: [Int: TextPageView] = [:]
    /// 可复用的空闲视图。
    private var reusableViews: [TextPageView] = []

    init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    /// 取出指定相对页的视图。不存在时从复用队列取或新建。
    func view(for relativePage: Int, in container: UIView) -> TextPageView {
        if let existing = activeViews[relativePage] {
            return existing
        }

        let view: TextPageView
        if let reused = reusableViews.popLast() {
            view = reused
        } else {
            view = TextPageView(frame: container.bounds)
        }

        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if view.superview !== container {
            container.addSubview(view)
        }
        activeViews[relativePage] = view
        return view
    }

    /// 移除不在保留集合中的视图。
    ///
    /// - Parameter keeping: 需要保留的相对页号。
    func recycle(except keeping: Set<Int>) {
        let toRemove = activeViews.keys.filter { !keeping.contains($0) }
        for key in toRemove {
            guard let view = activeViews.removeValue(forKey: key) else { continue }
            view.removeFromSuperview()
            view.prepareForReuse()
            reusableViews.append(view)
        }
    }

    /// 清空所有视图（关闭书籍时调用）。
    func removeAll() {
        for (_, view) in activeViews {
            view.removeFromSuperview()
            view.prepareForReuse()
            reusableViews.append(view)
        }
        activeViews.removeAll()
    }

    /// 当前活跃视图数量。
    var activeCount: Int { activeViews.count }
}
