# iOS 26+ 原生阅读器 —— 完整实现提示词

> **本文档是给 AI 编码代理的完整实现指令。**
> 阅读顺序：先读 §2「已核实事实」和 §3「硬性约束」，再读 §4「架构」，最后按 §19「里程碑」逐步实现。
> 凡本文档标注 `【待本地核实】` 的条目，必须在动手前用 Xcode SDK / 官方文档确认，**不得凭记忆写 API**。

---

## 0. 如何使用本文档

本文档包含四类信息，不要混用：

| 类型 | 含义 | 处理方式 |
|---|---|---|
| **决策** | 已经拍板的技术选型 | 直接执行，不要重新论证 |
| **约束** | 不可违背的规则 | 违反即返工 |
| **规格** | 需要实现的行为与接口 | 按签名实现，细节可优化 |
| **待核实** | 需要查 SDK 确认 | 先查后写 |

**不要做的事**：不要把本文档当成"灵感清单"自由发挥。不要把未列出的第三方库加进工程。不要在没跑通当前里程碑前跳去做下一个。

---

## 1. 产品定义

### 1.1 一句话

一款**仅支持 iOS 26 / iPadOS 26 及以上**的原生阅读器，同一套 UI 同时承载**文字类书籍**（小说、轻小说、文档）与**图像类书籍**（漫画、条漫、画集、PDF），深度使用 iOS 26 的 Liquid Glass 设计语言。

### 1.2 目标用户与核心场景

- 中文用户为主，需要**中文排版**（首行缩进、标点挤压、避头尾、行距、段间距）。
- 大量本地文件导入（TXT 网文、EPUB、CBZ 漫画包）。
- 长时间沉浸阅读（单次 30 分钟以上），因此**性能、内存、进度可靠性**优先于功能数量。
- iPad 分屏 / 台前调度 / iPhone Duo 折叠态下阅读不中断、不丢位置。

### 1.3 明确的非目标（第一期不做）

- 不做在线书城、不做账号体系、不做社交。
- 不做 DRM 破解（Adobe ACS 明确不支持）。
- 不做 MOBI/AZW3 的**首发**支持（见 §7.7）。
- 不做中文竖排的**首发**支持（见 §2.4 平台限制）。
- 不做 macOS / visionOS 版本（但架构上不要写死 iOS-only 的假设）。

---

## 2. 已核实的技术事实（实现前必读）

### 2.1 平台与工具链

| 项 | 值 |
|---|---|
| 最低部署目标 | iOS 26.0 / iPadOS 26.0（**不做任何向下兼容分支**） |
| 语言 | Swift 6，开启 Strict Concurrency（`-strict-concurrency=complete`） |
| UI 框架 | SwiftUI（功能层 / 导航 / 设置 / 书架） |
| 阅读画布 | UIKit 内核 + `UIViewRepresentable` 桥接 |
| 数据层 | SwiftData（元数据）+ 文件系统（正文与缓存） |
| 依赖管理 | Swift Package Manager only |
| 目标设备 | iPhone（含 Duo 折叠）、iPad（含分屏、台前调度） |

**关键推论**：既然部署目标是 iOS 26，就**不需要**写 `if #available(iOS 26, *)` 分支。所有 iOS 26 API 直接使用。任何 `#available` 检查都是多余代码，应删除。

### 2.2 渲染内核选型结论

这是本项目最重要的技术决策。**不要重新论证，直接执行。**

#### 结论：三引擎并存，按内容类型路由

```
                    ┌─────────────────────────────┐
                    │   Publication Abstraction   │
                    │   (统一内容模型 + Locator)    │
                    └──────────────┬──────────────┘
                                   │  Router
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
   │ TextKit 2 Engine │  │  WebKit Engine   │  │  Image Engine    │
   │  (文字主引擎)      │  │  (富内容兜底)      │  │  (漫画/PDF)       │
   ├──────────────────┤  ├──────────────────┤  ├──────────────────┤
   │ TXT / MD / HTML  │  │ EPUB 固定布局     │  │ CBZ / CBR / CB7  │
   │ EPUB 可重排       │  │ 含 SVG / MathML  │  │ 图片文件夹        │
   │ FB2              │  │ 竖排中文（可选）   │  │ PDF (PDFKit)     │
   └──────────────────┘  └──────────────────┘  └──────────────────┘
```

#### 为什么文字主引擎选 TextKit 2 而不是 WKWebView

| 维度 | TextKit 2 | WKWebView（如 Readium EPUBNavigator） |
|---|---|---|
| 中文精细排版 | 完全可控（段落样式、标点、行距） | 受 CSS 能力限制，标点挤压/避头尾支持弱 |
| 分页控制 | 自主决定断点，可精确到字符 | 依赖 CSS multi-column，断点不可控 |
| 进度精度 | 字符偏移级，字体变化后可精确恢复 | 依赖 CFI / 滚动比例，跨排版易漂移 |
| 翻页延迟 | 亚帧级（纯绘制） | 需处理 WebContent 进程 IPC |
| 内存 | 单进程，可控 | 多 WebContent 进程，长书易涨 |
| 字体切换 | 局部失效重排 | 全局 CSS 重算 + 回流 |
| 选词/标注 | `NSTextSelectionNavigation` 原生 | JS 注入，跨页选区麻烦 |
| 富内容（SVG/MathML/复杂 CSS） | 不支持 | 原生支持 |
| 竖排 | **不支持** | CSS `writing-mode: vertical-rl` 支持 |

**决策**：文字类内容的**主路径走 TextKit 2**；WebKit 只做「TextKit 2 无法胜任的富内容」和「用户显式切换到竖排」的兜底。

#### 为什么漫画不用 WKWebView

漫画是纯图像序列，用 WebKit 会引入无谓的 WebContent 进程、CSS 布局开销和手势冲突。正确做法是 `UICollectionView`（分页）/ `UIScrollView + LazyVStack`（条漫）+ ImageIO 降采样。

#### 为什么不用 CoreText 直接画

CoreText 给你完全自由，但选词、光标、注音、图文混排、RTL、文本选择菜单、无障碍全部要自研。TextKit 2 是 CoreText 之上的现代封装，已经提供这些能力，且支持懒布局与增量失效。**除非需要竖排，否则没有理由降到 CoreText。**

#### 为什么不用 TextKit 1

TextKit 1 的「一个 `NSLayoutManager` 挂多个 `NSTextContainer`」分页模式在长文本（几十万字）下内存暴涨、全量重排、RTL 与图文混排易错位。Apple 已明确主推 TextKit 2。**禁止使用 TextKit 1 的多容器分页。**

### 2.3 第三方依赖白名单

**只允许以下依赖。添加其他依赖需要用户明确批准。**

| 依赖 | 版本 | 许可证 | 用途 | 备注 |
|---|---|---|---|---|
| [Readium Swift Toolkit](https://github.com/readium/swift-toolkit) | 最新 3.x | BSD-3-Clause | EPUB 2/3 解析、OPF/manifest、CFI、LCP（可选） | 只用 `ReadiumShared` + `ReadiumStreamer`，**不用** `ReadiumNavigator` 的 EPUBNavigator（我们自建渲染） |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.x | MIT | ZIP / CBZ 读取与流式解压 | 基于 libcompression，无外部依赖 |
| [libarchive-swift](https://github.com/everpcpc/libarchive-swift) | 0.1.x | BSD-2-Clause（libarchive 本体） | RAR / RAR5 / 7z / CAB / ISO 读取 | 读-only，覆盖 CBR/CB7；若不引入则 CBR/CB7 延后 |
| [UnrarKit](https://github.com/abbeycode/UnrarKit) | 2.x | MIT（wrapper）+ RARLAB 受限条款 | CBR 备选方案 | 仅当 libarchive-swift 的 RAR 覆盖不足时启用；注意 RARLAB 条款限制 |

**明确禁止引入**：
- 任何"Liquid Glass 复刻"库（`glassmorphism`、`SwiftGlass` 之类）。
- 任何 `SDWebImage` / `Kingfisher` 类图片库（用 ImageIO + 自建 LRU 缓存）。
- 任何 EPUB 渲染库（Readium 的 Navigator 也不用）。
- 任何 `SwiftUI` 分页/滚动库。

### 2.4 已知平台限制（必须写进设计）

| 限制 | 影响 | 应对 |
|---|---|---|
| **TextKit 2 不支持垂直排版** | 中文竖排无法用主引擎 | 竖排时路由到 WebKit 引擎（CSS `writing-mode`）；或第一期不做竖排 |
| **TextKit 2 对 ruby 注音支持有限** | 日文轻小说注音难做 | 用行高预留 + `NSTextAttachment` 叠加；标记为风险项 |
| **`NSTextLayoutManager` 非线程安全** | 不能跨队列共享 | 每页独立实例，只在专属串行队列内创建与使用；跨队列只传不可变快照 |
| **WKWebView 的 `allowsContentJavaScript`** | EPUB 内可能含恶意脚本 | 见 §15.4：禁用内容脚本，仅注入自己的桥接脚本 |
| **SwiftData 不适合存大段文本** | 章节正文塞数据库会拖慢 | 正文存文件，数据库只存索引与元数据 |
| **`UIScreen.main` 在 iPad 分屏 / Duo 下不可靠** | 布局错乱 | 一律用 `GeometryReader` / `onGeometryChange` / size class |

### 2.5 iOS 26 关键 API 清单

**以下为 iOS 26 可用（部署目标即 26，直接调用，无需 `#available`）：**

- `Tab`（值驱动）+ `.tabViewStyle(.sidebarAdaptable)` —— 书架/书库导航在 iPad 上自动变侧栏
- `.glassEffect(.regular)` / `.glassEffect(.clear)`、`GlassEffectContainer(spacing:)`、`.glassEffectID(_:in:)` —— 仅用于功能层
- `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`
- `safeAreaBar(edge:alignment:spacing:content:)` —— 自定义阅读工具条
- `ConcentricRectangle()` —— 与屏幕/面板边缘同心圆角
- `backgroundExtensionEffect()` —— 侧栏/检查器后的镜像延展
- `.font(.body.scaled(by:))` —— 自定义缩放（替代 `@ScaledMetric` 的部分场景）
- SwiftUI `WebView`（`import WebKit`）—— 替代手写 `UIViewRepresentable` 包 `WKWebView`；**但本项目 WebKit 引擎需要精细的 delegate 与 JS 桥接，仍建议用 `UIViewRepresentable` 包 `WKWebView`，`WebView` 仅用于纯展示场景**
- `onGeometryChange(for:of:action:)` —— 替代 `GeometryReader` 做尺寸监听
- `.scrollEdgeEffectStyle(_:for:)`、`.scrollIndicators(.hidden)`

**以下为 iOS 27 才可用（本项目不使用，不要写进代码）：**

- `ToolbarOverflowMenu`、`visibilityPriority(_:)`、`.topBarPinnedTrailing`
- `.tabBarMinimizeBehavior(.onScrollDown)`
- `.toolbarMinimizationBehavior(_:for:)`
- `ArrangementView`

> 如果未来要支持 iOS 27，再引入。现在写进去会导致编译失败。

---

## 3. 硬性约束（不可违背）

### 3.1 架构约束

1. **SwiftUI 只管功能层**。阅读画布必须是 `UIViewRepresentable` 包裹的 UIKit 视图。禁止用纯 SwiftUI 视图逐字渲染长文本（几千个 `Text` 视图 = 几千个 layout 节点）。
2. **状态所有权唯一**。每本书的阅读状态（位置、设置）由 `ReaderSession`（`@Observable`）持有，放在场景根，不在子视图里 `@State` 复制一份。
3. **正文不进数据库**。章节文本落地为文件，SwiftData 只存 `Book` / `Chapter` 索引 / `Annotation` / `ReadingProgress`。
4. **Locator 是唯一位置真相**。任何"第几页""滚动百分比"都必须能还原成 `Locator`，反之亦然。禁止用 `pageIndex` 作为持久化进度。
5. **渲染引擎无 UI 依赖**。`TextKitEngine` 不得 `import SwiftUI`，只依赖 UIKit + Foundation。

### 3.2 视觉约束

6. **Liquid Glass 只用于功能层**：导航栏、工具栏、Tab、菜单、Sheet、浮动控制条。正文区域、卡片、列表行**禁止**加 `.glassEffect()`。
7. **禁止手搓玻璃**：不得用 `.ultraThinMaterial` + 渐变 + 模糊模拟玻璃。`Material` 只用于内容层的分隔，不用于冒充 Liquid Glass。
8. **阅读界面默认全沉浸**：正文铺满，工具栏以 `safeAreaBar` 浮于内容之上，滚动/点击切换显隐。
9. **主题色只在功能层克制使用**，正文颜色由阅读主题（日间/夜间/羊皮纸/护眼绿）决定。
10. **禁止用颜色作为唯一语义载体**（进度、选中、错误都要有形状或文字配合）。

### 3.3 代码约束

11. 禁止 `AnyView`（用泛型、`Group` 或提取 `View` struct）。
12. 禁止强制解包 `!`（`IBOutlet` 与已证明非空处除外，需注释理由）。
13. 禁止 `UIScreen.main`。
14. 禁止 `DispatchQueue.main.asyncAfter` 猜时间做动画链（用 `withAnimation(_:completion:)`）。
15. 禁止用索引作为 `ForEach` 的 `id`（可变集合）。
16. 禁止在 `body` 里做排序、过滤、日期格式化、正则。
17. 禁止字符串拼接构造 `Text`（破坏本地化）。
18. 禁止 `foregroundColor()` / `cornerRadius()` / `accentColor()` / `tabItem()` / `navigationBarTrailing` 等软废弃 API。
19. 所有 `try!` / `fatalError` 仅允许出现在 `#Preview` 与不可达分支，且需注释。
20. 新增公开 API 必须有文档注释（`///`），说明线程约束。

### 3.4 验证约束

21. 每个里程碑结束必须：`xcodebuild build` 零警告 + 跑通该里程碑的验收用例。
22. 涉及渲染的改动必须在真机（非仅模拟器）验证翻页帧率。
23. 无法验证的部分必须**明说**，不得假装通过。

---

## 4. 架构总览

### 4.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│  App / Scene                                                  │
│  LibraryView · ReaderView · SettingsView  (SwiftUI)           │
├──────────────────────────────────────────────────────────────┤
│  Feature Layer (SwiftUI + @Observable)                        │
│  LibraryStore · ReaderSession · ReaderSettings · AnnotationStore │
├──────────────────────────────────────────────────────────────┤
│  Domain Layer (Pure Swift, no UIKit)                          │
│  Publication · Locator · Chapter · ReadingProgress · Bookmark │
├──────────────────────────────────────────────────────────────┤
│  Service Layer                                                │
│  ImportService · FormatRouter · EncodingDetector · PageCache  │
├──────────────────────────────────────────────────────────────┤
│  Render Layer (UIKit)                                         │
│  TextKitEngine · WebKitEngine · ImageEngine · PDFEngine       │
├──────────────────────────────────────────────────────────────┤
│  Storage Layer                                                │
│  SwiftData (metadata) · FileStore (content) · BookmarkStore   │
└──────────────────────────────────────────────────────────────┘
```

**依赖方向严格单向向下。** Domain 层不得 `import UIKit`。

### 4.2 目录结构

```
ReaderApp/
├── App/
│   ├── ReaderApp.swift
│   ├── AppContainer.swift          // 依赖注入根
│   └── AppScene.swift
├── Domain/
│   ├── Publication/
│   │   ├── Publication.swift
│   │   ├── PublicationMetadata.swift
│   │   ├── Resource.swift
│   │   └── ReadingOrder.swift
│   ├── Locator/
│   │   ├── Locator.swift
│   │   ├── LocatorLocations.swift
│   │   ├── TextQuote.swift
│   │   └── LocatorResolver.swift
│   ├── Chapter/
│   │   └── Chapter.swift
│   └── Progress/
│       ├── ReadingProgress.swift
│       └── ProgressMapper.swift
├── Services/
│   ├── Import/
│   │   ├── ImportService.swift
│   │   ├── SecurityScopedBookmarkStore.swift
│   │   └── FormatSniffer.swift
│   ├── Encoding/
│   │   └── TextEncodingDetector.swift
│   ├── Archive/
│   │   ├── ArchiveReader.swift          // 协议
│   │   ├── ZIPArchiveReader.swift
│   │   └── LibArchiveReader.swift
│   ├── Parsing/
│   │   ├── TextPublicationParser.swift  // TXT / MD
│   │   ├── ChapterSplitter.swift
│   │   ├── EPUBPublicationParser.swift  // 基于 Readium
│   │   ├── ComicPublicationParser.swift
│   │   └── PDFPublicationParser.swift
│   └── Cache/
│       ├── PageIndexCache.swift
│       └── ImageCache.swift
├── Render/
│   ├── RenderEngine.swift               // 协议
│   ├── TextKit/
│   │   ├── TextKitEngine.swift
│   │   ├── TextPageView.swift
│   │   ├── Paginator.swift
│   │   ├── PageLayoutSnapshot.swift
│   │   ├── PagePool.swift
│   │   └── TypographyProfile.swift
│   ├── WebKit/
│   │   ├── WebKitEngine.swift
│   │   ├── ReaderCSSInjector.swift
│   │   └── WebBridge.swift
│   ├── Image/
│   │   ├── ComicPagedEngine.swift
│   │   ├── ComicWebtoonEngine.swift
│   │   ├── SpreadResolver.swift
│   │   └── ImageDownsampler.swift
│   └── PDF/
│       └── PDFEngine.swift
├── Features/
│   ├── Library/
│   ├── Reader/
│   │   ├── ReaderView.swift
│   │   ├── ReaderSession.swift
│   │   ├── ReaderChrome.swift          // 顶部/底部浮动工具条
│   │   ├── TOCPanel.swift
│   │   ├── ReaderSettingsPanel.swift
│   │   └── ProgressScrubber.swift
│   ├── Annotations/
│   └── Settings/
├── DesignSystem/
│   ├── ReaderTheme.swift
│   ├── Typography.swift
│   ├── Spacing.swift
│   └── GlassSurfaces.swift
└── Resources/
    ├── Localizable.xcstrings
    └── Assets.xcassets
```

### 4.3 数据流

```
导入文件
  → FormatSniffer（按扩展名 + 魔数嗅探真实类型）
  → ImportService（安全范围访问 → 复制到沙盒 → 解析）
  → Parser（产出 Publication + 章节文件落地）
  → SwiftData 写入 Book 记录
  → 书架刷新

打开书籍
  → ReaderSession 创建
  → FormatRouter 选择 RenderEngine
  → Engine 加载 Resource + Locator
  → 渲染
  → 用户翻页 → Engine 产出新 Locator
  → ReaderSession 节流保存进度（≥1s 间隔或离开页面时）
```

### 4.4 并发模型

- **UI 状态**：`@MainActor`。
- **解析 / 解压 / 分页计算**：`nonisolated` + 专用 `actor` 或 `Task.detached`。
- **TextKit 布局**：每页一个**专属串行队列**（`DispatchSerialQueue`），该队列内创建并使用 `NSTextLayoutManager`。跨队列只传 `PageLayoutSnapshot`（值类型，不可变）。
- **图片解码**：`Task.detached(priority: .userInitiated)`，产出 `CGImage`（`Sendable`）。
- **进度保存**：`MainActor` 上节流，写入用 `Task` 异步。

**禁止**：把 `NSTextLayoutManager`、`NSTextContentStorage`、`WKWebView` 标记为 `Sendable` 或跨 actor 传递。

---

## 5. 领域模型

```swift
// MARK: - Publication

/// 一本书的抽象。与具体格式无关。
struct Publication: Identifiable, Hashable, Sendable {
    let id: UUID
    var metadata: PublicationMetadata
    var kind: PublicationKind
    var readingOrder: [Resource]      // 章节 / 页面资源，顺序即阅读顺序
    var tableOfContents: [TOCItem]
    var layout: LayoutStyle           // .reflowable / .fixed
    var readingProgression: ReadingProgression  // .ltr / .rtl
    var baseURL: URL                  // 资源根目录（沙盒内）
}

enum PublicationKind: String, Codable, Sendable {
    case text          // TXT / MD / FB2
    case epubReflowable
    case epubFixedLayout
    case comic         // CBZ / CBR / CB7 / 图片文件夹
    case pdf
    case webtoon       // 长条漫（竖向连续）
}

enum LayoutStyle: String, Codable, Sendable {
    case reflowable    // 文字重排
    case fixed         // 固定版式（图像/预排版）
}

enum ReadingProgression: String, Codable, Sendable {
    case ltr, rtl      // 日漫 / 中文竖排为 rtl
}

struct PublicationMetadata: Codable, Hashable, Sendable {
    var title: String
    var author: String?
    var publisher: String?
    var language: String?
    var coverURL: URL?
    var identifier: String?
    var description: String?
    var tags: [String]
    var wordCount: Int?
}

/// 一个可寻址资源（一个章节，或一页图）。
struct Resource: Identifiable, Hashable, Sendable {
    let id: String            // 相对 href，如 "OEBPS/chapter1.xhtml"
    var href: String
    var mediaType: String     // "application/xhtml+xml" / "image/jpeg"
    var title: String?
    var byteSize: Int64?
}
```

```swift
// MARK: - Locator

/// 全书唯一位置真相。任何阅读位置都必须能表达为 Locator。
struct Locator: Codable, Hashable, Sendable {
    var href: String              // 指向 Resource.href
    var mediaType: String
    var locations: Locations
    var text: TextQuote?          // 用于模糊重定位（换排版/换源后仍能找回）
}

struct Locations: Codable, Hashable, Sendable {
    /// 资源内进度 0...1（用于无字符偏移能力的引擎，如 PDF）
    var progression: Double?
    /// 全书进度 0...1（用于进度条、统计）
    var totalProgression: Double?
    /// 资源内字符偏移（UTF-16 code unit），文字引擎的主定位
    var charOffset: Int?
    /// 资源内页码（图像引擎）
    var page: Int?
    /// 精确定位片段（EPUB CFI 片段 / 图像区域）
    var fragments: [String]?
}

struct TextQuote: Codable, Hashable, Sendable {
    var before: String?    // 目标前 30 字
    var highlight: String  // 目标本身
    var after: String?     // 目标后 30 字
}
```

**重定位优先级**（`LocatorResolver`）：
1. `fragments` 精确匹配（EPUB CFI）
2. `charOffset` 直接定位（同一排版指纹下有效）
3. `text.highlight` 在资源内模糊搜索（允许 1~2 字差异，用 `String.CompareOptions.diacriticInsensitive` + 编辑距离）
4. `progression` 按比例落到最近的段落
5. 兜底：资源开头

> 这是保证「换字号后不丢位置」「换设备后不丢位置」的核心。必须写单元测试。

```swift
// MARK: - 阅读进度

struct ReadingProgress: Codable, Hashable, Sendable {
    var bookID: UUID
    var locator: Locator
    var totalProgression: Double     // 0...1
    var updatedAt: Date
    var isFinished: Bool
}

// MARK: - 标注

struct Annotation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var bookID: UUID
    var locator: Locator
    var selectedText: String         // 上限 2000 字
    var style: AnnotationStyle       // .highlight / .underline / .note
    var colorName: String?           // 语义名，不存 hex
    var note: String?
    var createdAt: Date
    var modifiedAt: Date
}
```

---

## 6. 内容抽象层

### 6.1 核心协议

```swift
/// 格式解析器。每种格式一个实现。
protocol PublicationParser: Sendable {
    static var supportedExtensions: Set<String> { get }
    /// 是否处理该文件（扩展名 + 魔数）
    static func canOpen(url: URL) -> Bool
    /// 解析为统一模型；章节正文落地到 fileStore
    func parse(url: URL, fileStore: FileStore) async throws -> Publication
}

/// 内容提供者。引擎通过它取内容，不直接碰文件。
protocol ContentProvider: Sendable {
    func metadata() async throws -> PublicationMetadata
    func readingOrder() async throws -> [Resource]
    /// 取纯文本（文字引擎用）
    func text(for resource: Resource) async throws -> NSAttributedString
    /// 取 HTML（WebKit 引擎用）
    func html(for resource: Resource) async throws -> String
    /// 取图片数据（图像引擎用，返回未解码 Data）
    func data(for resource: Resource) async throws -> Data
    /// 取章节起点的 Locator（用于"跳到下一章"）
    func locator(forChapterAt index: Int) async throws -> Locator
}
```

### 6.2 格式路由

```swift
enum FormatRouter {
    static func engineKind(for publication: Publication, settings: ReaderSettings) -> EngineKind {
        switch publication.kind {
        case .text, .epubReflowable:
            // 用户选了竖排 → 必须走 WebKit
            if settings.writingMode == .vertical { return .webKit }
            return .textKit
        case .epubFixedLayout:
            return .webKit
        case .comic:
            return settings.webtoonMode ? .imageWebtoon : .imagePaged
        case .webtoon:
            return .imageWebtoon
        case .pdf:
            return .pdf
        }
    }
}
```

---

## 7. 格式适配器规范

### 7.1 支持矩阵

| 格式 | 扩展名 | 第一期 | 解析方式 | 渲染引擎 |
|---|---|---|---|---|
| 纯文本 | `.txt` | ✅ | 自研（编码探测 + 章节切分） | TextKit |
| Markdown | `.md` `.markdown` | ✅ | 自研（→ NSAttributedString） | TextKit |
| HTML | `.html` `.htm` | ✅ | 自研（→ NSAttributedString，剥脚本） | TextKit |
| EPUB 2/3 可重排 | `.epub` | ✅ | Readium | TextKit |
| EPUB 固定布局 | `.epub` | ✅ | Readium | WebKit |
| PDF | `.pdf` | ✅ | PDFKit | PDF |
| 漫画包 ZIP | `.cbz` `.zip` | ✅ | ZIPFoundation | Image |
| 图片文件夹 | 目录 | ✅ | FileManager | Image |
| RAR 漫画 | `.cbr` `.rar` | ✅（第二期） | libarchive-swift | Image |
| 7z 漫画 | `.cb7` `.7z` | ✅（第二期） | libarchive-swift | Image |
| FB2 | `.fb2` | ⬜（第三期） | 自研 XML → HTML | TextKit |
| MOBI / AZW3 | `.mobi` `.azw3` | ⬜（第三期，需评估许可） | libmobi（LGPL-3.0，需法务确认） | TextKit |
| KEPUB | `.kepub.epub` | ⬜ | 同 EPUB | TextKit |
| UMD | `.umd` | ❌ | 格式过时、编码混乱 | — |

**第一期只做 ✅ 项。** 不要在 M1 阶段写 FB2。

### 7.2 TXT 解析器（最容易做错的部分）

#### 7.2.1 编码探测

`NSString(contentsOf:usedEncoding:)` 对 GBK 常误判为 UTF-8，**不可单独使用**。必须实现显式探测链：

```swift
enum TextEncodingDetector {
    /// 探测顺序（不可调换）
    static func detect(data: Data) -> (String.Encoding, String)
}
```

探测顺序：

1. **BOM 检测**（最高优先级）
   - `EF BB BF` → UTF-8
   - `FF FE` → UTF-16LE
   - `FE FF` → UTF-16BE
2. **UTF-8 严格校验**：用 `String(data:encoding:.utf8)`，若成功且不含 `U+FFFD` → UTF-8
3. **UTF-16 无 BOM 启发**：前 2KB 中 `0x00` 出现在奇数/偶数位比例 > 30% → 判为 UTF-16LE/BE
4. **中文优先**：GB18030（`CFStringEncodings.GB_18030_2000`）→ Big5（`CFStringEncodings.big5`）→ GBK
   - 判定标准：解码后中文字符（`U+4E00...U+9FFF`）占比 > 15%，且控制字符占比 < 1%
5. **日文**：Shift-JIS（`CFStringEncodings.shiftJIS`）→ EUC-JP
6. **韩文**：EUC-KR
7. **西文**：Windows-1252 / ISO-8859-1
8. **兜底**：UTF-8 + 替换字符（并给用户提示"编码可能有误"，提供手动切换入口）

**实现要点**：
- GB18030 在 Foundation 中需通过 `CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))` 获取。
- 探测只看前 64KB（`data.prefix(65536)`），避免大文件全量扫描。
- 探测结果写入 `Book.detectedEncoding`，允许用户在阅读设置中手动覆盖。
- 必须提供语料测试：GBK / GB18030 / UTF-8 / UTF-8-BOM / UTF-16LE / Big5 / Shift-JIS 各一份，断言无乱码。

#### 7.2.2 章节切分

```swift
struct ChapterSplitter {
    /// 返回 [(title, range)]，range 为 UTF-16 偏移
    static func split(_ text: String) -> [ChapterRange]
}
```

规则：

1. 按行扫描，对每行做多正则匹配（优先级从上到下）：
   ```
   ^\s*第[零一二三四五六七八九十百千万两\d]{1,10}[章节回卷集部篇话]\s*[^\n]{0,40}$
   ^\s*(序章|楔子|引子|前言|序言|后记|尾声|番外)[^\n]{0,40}$
   ^\s*Chapter\s+\d+[^\n]{0,60}$          (i)
   ^\s*[（(]\d{1,4}[）)][^\n]{0,40}$
   ^\s*\d{1,4}[.、]\s*[^\n]{0,40}$        (仅在候选章节 ≥ 20 时才启用，防误判)
   ```
2. **阈值保护**：若匹配到的章节数 < 3，视为「无章节」，整本作为单章（但按固定字符数虚拟分块，如每 8000 字一块，用于分页缓存）。
3. **单章长度上限**：若某章 > 100,000 字，按段落边界二次切分为虚拟块（不显示在目录，仅用于分页性能）。
4. 章节标题清洗：去首尾空白、全角空格、不可见字符。
5. 切分结果**必须与原文偏移严格对应**，禁止重新拼接字符串。

#### 7.2.3 落地格式

```
<AppSupport>/Books/<bookID>/
├── meta.json                 // PublicationMetadata
├── chapters/
│   ├── 0000.txt              // UTF-8 编码，已归一化换行
│   ├── 0001.txt
│   └── ...
└── index.json                // [ChapterIndex { title, file, charOffsetStart, charCount }]
```

- 换行统一为 `\n`（`\r\n` / `\r` → `\n`）。
- 去除 `\u{FEFF}`、`\u{200B}`、`\u{00A0}` 等不可见字符（保留段内普通空格）。
- 正文文件必须是 UTF-8，与原始编码解耦。

### 7.3 Markdown / HTML 解析器

- Markdown：只支持 CommonMark 子集（标题、段落、强调、列表、引用、代码块、链接、图片）。**不要引入 markdown 解析库**，手写 ~200 行的行扫描器足够。
- HTML：`NSAttributedString(data:options:documentType:.html)` 可用但慢且样式失控。推荐用 `XMLParser` 提取文本 + 段落结构，再手工构造 `NSAttributedString`。
- **必须剥离** `<script>`、`<style>`、`<iframe>`、事件属性。
- 图片：`<img>` 解析为 `NSTextAttachment`（从相对路径加载并降采样）。

### 7.4 EPUB 解析器

使用 Readium `ReadiumShared` + `ReadiumStreamer`：

```swift
import ReadiumShared
import ReadiumStreamer

final class EPUBPublicationParser: PublicationParser {
    func parse(url: URL, fileStore: FileStore) async throws -> Publication {
        let asset = FileAsset(url: url)
        let publication = try await streamer.open(asset: asset, allowUserInteraction: false)
        // 1. 抽取 metadata → PublicationMetadata
        // 2. readingOrder → [Resource]
        // 3. tableOfContents → [TOCItem]
        // 4. 判定 layout：publication.metadata.presentation.layout == .fixed ? .fixed : .reflowable
        // 5. 判定 readingProgression（EPUB 的 page-progression-direction）
    }
}
```

**关键点**：
- **只用 Readium 的解析能力**，不用 `EPUBNavigatorViewController`。
- 章节正文：通过 `publication.content()` 或 resource 读取 XHTML → 用 §7.3 的 HTML 解析器转 `NSAttributedString`。
- 图片/字体等资源：Readium 提供相对路径解析，但建议**解压 EPUB 到沙盒目录**后用普通文件访问，性能更好、调试更方便。
- **解压策略**：EPUB 本质是 ZIP。导入时直接解压到 `Books/<bookID>/extracted/`，之后一切按本地文件处理。这样也规避了 `file://` 与 WKWebView 的沙盒限制。
- 必须处理：`META-INF/container.xml` 缺失、`OPF` 路径异常、`spine` 为空等损坏文件，给出明确错误而不是崩溃。
- EPUB 内 XHTML 的 CSS：**不解析**（TextKit 不支持 CSS）。只提取语义结构（h1-h6、p、em、strong、blockquote、ul/ol、img）。
- 固定布局 EPUB：保留原始 HTML + CSS，交给 WebKit 引擎。

### 7.5 PDF 解析器

- 用 `PDFKit.PDFDocument`。
- `readingOrder` = 页（每页一个 `Resource`，`mediaType = "application/pdf"`）。
- 文字层可选：`page.string` 用于搜索与进度，但**不做重排**。
- 加密 PDF：检测 `isEncrypted`，提示用户，不做破解。

### 7.6 漫画解析器（CBZ / CBR / CB7 / 文件夹）

```swift
protocol ArchiveReader: Sendable {
    func entries(at url: URL) throws -> [ArchiveEntry]
    func data(for entry: ArchiveEntry, in url: URL) throws -> Data
    func extract(_ url: URL, to destination: URL, limits: ExtractionLimits) throws
}

struct ExtractionLimits: Sendable {
    var maxEntryCount = 20_000
    var maxEntrySize: Int64 = 512 * 1024 * 1024
    var maxTotalSize: Int64 = 8 * 1024 * 1024 * 1024
    var maxCompressionRatio = 200.0     // 防 zip bomb
}
```

**实现要点**：

1. **入口排序**：按路径做「自然排序」（`chapter2` 在 `chapter10` 前）。用 `localizedStandardCompare`，并对纯数字文件名做数值比较。
2. **过滤**：只保留 `jpg/jpeg/png/heic/heif/webp/gif/bmp/tiff/avif`；忽略 `__MACOSX/`、`.DS_Store`、`Thumbs.db`、隐藏文件、目录项。
3. **不整包解压**：CBZ 走 ZIPFoundation 的**按需读取**（`Archive[path]`），避免几百 MB 漫画包全部落盘。CBR/CB7 若 libarchive 支持随机访问则同样按需，否则解压到临时目录并做 LRU 清理。
4. **文件名编码**：国漫 ZIP 常见 GBK 文件名。ZIPFoundation 的 entry path 是 `String`，若出现乱码，用 `CFStringConvertEncodingToNSStringEncoding` 走 GB18030 重解码原始字节（需要 ZIPFoundation 的 raw path 支持，或改用自己的 ZIP 中央目录解析）。
5. **webp 支持**：iOS 14+ 原生支持 WebP 解码（ImageIO）。确认 `CGImageSourceCreateWithData` 能处理即可。
6. **AVIF**：iOS 16+ 支持。需实测。

**漫画元数据**：
- 优先读 `ComicInfo.xml`（ComicRack 标准），提取 `Title` / `Series` / `Number` / `Summary` / `PageCount`。
- 无则从文件名推断（`[作者] 标题 第03卷.cbz`）。
- 封面 = 第一张图（但如果是跨页图，用第二张）。

### 7.7 FB2 / MOBI / AZW3（第三期）

- **FB2**：XML 格式，`XMLParser` 提取 `<section>` / `<title>` / `<p>`，转 HTML 或 `NSAttributedString`。无依赖，难度低。
- **MOBI/AZW3**：需要 `libmobi`（LGPL-3.0）。LGPL 在 App Store 静态链接场景存在合规争议，**必须先让用户确认法务风险**。备选：仅支持 AZW3 中的 KF8 部分，或用纯 Swift 的 PalmDB + MOBI 解析（工作量大）。
- **在用户明确批准前，不要动这一节。**

---

## 8. 渲染引擎规范

### 8.1 引擎协议

```swift
@MainActor
protocol RenderEngine: AnyObject {
    var kind: EngineKind { get }
    /// 当前可视位置的 Locator
    var currentLocator: Locator { get }
    /// 全书进度 0...1
    var totalProgression: Double { get }

    func load(publication: Publication,
              provider: ContentProvider,
              initialLocator: Locator?,
              settings: ReaderSettings) async throws

    func apply(settings: ReaderSettings)
    func go(to locator: Locator, animated: Bool) async
    func nextPage() async -> Bool      // 返回 false 表示已到结尾
    func previousPage() async -> Bool
    func nextChapter() async
    func previousChapter() async

    /// 当前可见文本（VoiceOver / 选中 / 搜索用）
    func visibleText() -> String?
    /// 用户点击回调（用于显示/隐藏 chrome）
    var onInteraction: ((ReaderInteraction) -> Void)? { get set }
    /// 位置变化回调（节流后上报）
    var onLocatorChange: ((Locator) -> Void)? { get set }
    /// 标注渲染
    func setAnnotations(_ annotations: [Annotation])
    /// 选中文本
    func selection() -> (text: String, locator: Locator)?
}

enum EngineKind: String, Sendable {
    case textKit, webKit, imagePaged, imageWebtoon, pdf
}

enum ReaderInteraction: Sendable {
    case tapCenter, tapLeft, tapRight, longPress, selectionChanged
}
```

### 8.2 TextKit 2 文字引擎（核心，最详细）

#### 8.2.1 视图结构

```
TextKitEngine (UIViewController)
└── TextPageView (UIView)   × 页面池（当前 ± 1）
    ├── 持有 NSTextContentStorage
    ├── 持有 NSTextLayoutManager
    ├── 持有 NSTextContainer（尺寸 = 正文区域）
    └── draw(_:) 中通过 NSTextViewportLayoutController 渲染 fragments
```

**禁止**：用 `UITextView` 做分页容器。`UITextView` 内置 TextKit 2 但封装过深，无法精确控制分页与 fragment 生命周期。

#### 8.2.2 分页算法

```
输入：章节 NSAttributedString、页面尺寸（正文区域，已扣安全区与内边距）、排版参数
输出：PageBreakIndex = [PageSlice { range: NSRange, topInset: CGFloat }]
```

步骤：

1. 为章节创建**一个临时** `NSTextContentStorage` + `NSTextLayoutManager` + 尺寸为页面正文区的 `NSTextContainer`。
2. 设置 `layoutManager.usesFontLeading = true`、`layoutManager.usesHyphenation = false`（中文不需要；英文可配置）。
3. 用 `textLayoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout, .estimatesSize])` 逐段获取 fragment。
4. 累计每个 fragment 的 `layoutFragmentFrame.maxY`。
5. 当 `maxY > 页面可用高度` 时：
   - 取**上一个 fragment 的结束位置**作为本页终点；
   - 若单个 fragment 本身就超过一页高（如超长代码块/大图），用 `enumerateTextSegments(in:type:.layout)` 按行切分；
   - 记录断点 `NSRange`，从断点处继续下一页。
6. 循环直到文本结束，得到 `[PageSlice]`。
7. **断点微调**：
   - 避免孤行：若某页最后一行只有 1~2 个字且属于新段落，把该段落整体推到下一页（可选，按设置）。
   - 避免标题落页底：若页尾 fragment 是标题样式，推至下一页。

**性能要求**：10 万字章节分页 < 150ms（A17 及以上）。若超时，按段落边界切成虚拟子块分别分页（见 §7.2.2 第 3 条）。

#### 8.2.3 页面渲染

每个 `TextPageView` 只渲染一页：

```swift
final class TextPageView: UIView {
    private var contentStorage: NSTextContentStorage?
    private var layoutManager: NSTextLayoutManager?
    private var textContainer: NSTextContainer?
    private var viewportController: NSTextViewportLayoutController?

    func configure(slice: PageSlice, chapterText: NSAttributedString,
                   pageSize: CGSize, theme: ReaderTheme) {
        // 1. 只截取 slice.range 对应的子串（关键：不要每页持有整章）
        let pageText = chapterText.attributedSubstring(from: slice.range)
        // 2. 建立独立 TK2 栈
        // 3. 应用主题颜色（作为 rendering attributes，不改文本属性）
        // 4. setNeedsDisplay
    }

    override func draw(_ rect: CGRect) {
        guard let lm = layoutManager, let vc = viewportController else { return }
        vc.layoutViewport()
        lm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
    }
}
```

**关键决策**：
- **每页只截取自己的 `NSAttributedString` 子串**，不共享整章。这是内存可控的前提。
- 页面尺寸变化（旋转、分屏、Duo 折叠）→ 重新分页，用 `charOffset` 恢复位置。
- 主题切换（仅颜色）→ 只更新 rendering attributes + `setNeedsDisplay`，**不重新分页**。
- 字号/行距/字体切换 → 重新分页，用 `charOffset` 恢复。

#### 8.2.4 页面池与预布局

```
PagePool:
  - 容量 3（prev / current / next），可配 5
  - 复用 TextPageView 实例，只替换内容
  - 淘汰策略：LRU
  - 预布局：当前页渲染完成后，异步生成 prev/next 的 PageSlice 布局（只算 range，不建 view）
```

**线程规则（必须遵守）**：
- `NSTextLayoutManager` 及其关联对象**只能在其创建的队列上访问**。
- 每个 `TextPageView` 拥有一个 `DispatchSerialQueue`（`target: .global(qos: .userInitiated)`）。
- 跨队列只传 `PageSlice`（`Sendable` 值类型）。
- **不要**把布局对象做成 `actor` 然后跨 actor 传引用。

#### 8.2.5 进度映射

```
charOffset（章节内） ←→ PageSlice（页）
totalProgression = (章节起始偏移 + 页内偏移) / 全书总字符数
```

- 全书总字符数在导入时算好，存 `Book.totalCharacters`。
- 每页的 `totalProgression` 在分页时预先算好，避免滚动时实时计算。
- 进度条拖动 → 反查 `(章节 index, charOffset)` → 定位。

#### 8.2.6 手势与点击区域

默认三分区（可配置）：

```
┌─────────┬───────────┬─────────┐
│  左 1/4  │  中 1/2    │ 右 1/4  │
│  上一页   │  呼出/隐藏  │  下一页  │
└─────────┴───────────┴─────────┘
```

- 用 `UITapGestureRecognizer` 在 `TextPageView` 上判定落点。
- 长按 → 进入选词（`UITextInteraction` 或自建 `NSTextSelectionNavigation`）。
- 选词态下点击空白 → 退出选词，**不翻页**。
- 左右滑动 → 翻页（`UIPanGestureRecognizer` 或 `UISwipeGestureRecognizer`），阈值 ≥ 40pt，速度 > 300pt/s 也触发。
- **翻页动画**：
  - 默认 `.slide`（transform 位移 + 阴影），120~200ms。
  - 可选 `.fade`、`.none`（瞬切，适合快速阅读）。
  - **Reduce Motion 开启时强制 `.fade`**。

#### 8.2.7 标注渲染

- 用 `NSTextLayoutManager.addRenderingAttribute(_:value:for:)` 叠加高亮，**不修改文本存储**。
- 这样切换标注不会触发重新分页。
- 笔记图标：在 fragment 边界外绘制（`draw(_:)` 中自定义绘制），或在 `TextPageView` 上叠加 `UIView` 子视图。

#### 8.2.8 搜索

- 章节内搜索：`NSString.range(of:options:.caseInsensitive)` 遍历。
- 全书搜索：后台逐章扫描，流式返回结果，可取消。
- 结果列表点击 → 定位到 `Locator(charOffset:)`。

### 8.3 WebKit 引擎

用于：EPUB 固定布局、含 SVG/MathML 的内容、中文竖排。

```swift
final class WebKitEngine: NSObject, RenderEngine, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private var bridge: WebBridge
}
```

**配置要点**：

1. `WKWebViewConfiguration`：
   - `allowsInlineMediaPlayback = true`
   - `mediaTypesRequiringUserActionForPlayback = .all`（EPUB 音频不能自动播）
   - **`preferences.isElementFullscreenEnabled = false`**
   - 注入 `WKUserScript`（`.atDocumentEnd`, `forMainFrameOnly: true`）—— 只有自己的桥接脚本
2. **禁用内容脚本**：EPUB 的 XHTML 可能含 `<script>`。
   - 用 `WKContentRuleList` 或 `WKUserScript` 在文档开始前移除所有 `<script>`；
   - `javaScriptEnabled` 必须为 `true`（我们自己需要），但通过 `WKContentRuleList` 阻断外部脚本 URL。
3. 加载方式：`loadFileURL(extractedDir, allowingReadAccessTo: extractedDir)`。
4. CSS 注入：把 `ReaderTheme` 翻译为 CSS 变量，注入 `<style>`：
   ```css
   :root {
     --reader-bg: #F7F3E8;
     --reader-fg: #2B2B2B;
     --reader-font-size: 18px;
     --reader-line-height: 1.8;
     --reader-margin: 24px;
   }
   body { background: var(--reader-bg); color: var(--reader-fg); }
   ```
5. 进度桥接：
   ```js
   // 注入脚本
   window.readerBridge = {
     getProgress() { return window.scrollY / (document.body.scrollHeight - innerHeight); },
     scrollTo(p) { window.scrollTo(0, p * (document.body.scrollHeight - innerHeight)); },
     getVisibleText() { ... }
   };
   ```
   - 用 `WKScriptMessageHandler` 双向通信。
   - 分页模式（固定布局）用 CSS `column` + 翻页；滚动模式用 `scrollY`。
6. **竖排**：注入 `body { writing-mode: vertical-rl; }`，翻页方向改为 rtl。
7. **WKWebView 内存**：单本只保留一个实例；离开阅读器时 `webView.loadHTMLString("", baseURL: nil)` 释放内容。

### 8.4 图像引擎（漫画）

#### 8.4.1 分页模式（ComicPagedEngine）

```
UIViewController
└── UICollectionView (horizontal, pagingEnabled, isPrefetchingEnabled)
    └── ComicPageCell
        ├── ZoomableImageView (UIScrollView + UIImageView)
        └── 双击缩放 / 捏合缩放 / 拖拽平移
```

**要点**：

1. **降采样**：绝不直接 `UIImage(data:)`。
   ```swift
   func downsample(data: Data, to pointSize: CGSize, scale: CGFloat) -> CGImage? {
       let options: [CFString: Any] = [
           kCGImageSourceShouldCache: false,
           kCGImageSourceCreateThumbnailFromImageAlways: true,
           kCGImageSourceThumbnailMaxPixelSize: max(pointSize.width, pointSize.height) * scale,
           kCGImageSourceCreateThumbnailWithTransform: true,
       ]
       guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
       return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
   }
   ```
   - 目标尺寸 = 屏幕短边 × `UIScreen.scale`（用 `view.window?.screen.scale` 或 `traitCollection.displayScale`，**不用 `UIScreen.main`**）。
   - 缩放超过 2x 时，重新以更大尺寸解码（分级解码）。

2. **预取窗口**：当前页 ± 2 页解码并缓存，± 5 页只读 Data 不解码。
3. **内存预算**：同时驻留 `CGImage` ≤ 5 张；`NSCache` 总成本上限 = 128MB；收到 `didReceiveMemoryWarning` 时清空到只剩当前页。
4. **跨页识别**（`SpreadResolver`）：
   - 若图片 `width / height > 1.2` 且宽高比接近 2:1 或更宽 → 判定为跨页图，**单独占一屏**（不与其他页并排）。
   - iPad 横屏可开启「双页模式」：两张非跨页图并排。跨页图前后自动断开。
   - 双页模式下，页码索引要正确映射（第 3、4 页并排 → 显示 "3-4"）。
5. **阅读方向**：
   - `ltr`（国漫/美漫）：左 → 右。
   - `rtl`（日漫）：右 → 左。`UICollectionView` 的 `semanticContentAttribute = .forceRightToLeft`，或反转数据源。
6. **翻页动画**：默认瞬切（漫画阅读习惯），可选滑动。**不要**做 curl/page-curl（性能差、违和）。
7. **进度**：`pageIndex / totalPages`，同时存 `charOffset` 不适用 → 存 `Locator.locations.page`。

#### 8.4.2 条漫模式（ComicWebtoonEngine）

```
UIScrollView
└── LazyVStack-like 自建（UIStackView 不适合，用 UICollectionView vertical flow layout）
```

- 竖向连续滚动，图片宽度 = 容器宽度，高度按比例。
- 预加载：可见区域上下各 1.5 屏。
- 进度：`contentOffset.y / (contentSize.height - bounds.height)`。
- **限制**：单张图高度超过 3 屏时（超长条漫），需要切片加载（按 2000pt 分段），否则解码内存爆炸。

#### 8.4.3 图片缓存

```swift
final class ImageCache {
    private let decoded: NSCache<NSString, CGImageBox>   // 上限 128MB
    private let rawData: NSCache<NSString, NSData>       // 上限 64MB
    // key = "\(bookID)/\(entryPath)"
}
```

**禁止**用第三方图片库。ImageIO + NSCache 足够。

### 8.5 PDF 引擎

- `PDFView`（PDFKit），`displayMode = .singlePageContinuous` 或 `.singlePage`。
- 主题（夜间）：`pdfView.backgroundColor` + `pageOverlayViewProvider` 叠加暗色遮罩（PDFKit 在 iOS 16+ 支持 `PDFPageOverlayViewProvider`）。
- 进度：`document.index(for: page)` / `pageCount`。
- 文本选择：PDFKit 原生。
- **不做重排**（不做 PDF reflow，工作量与风险都过大）。

### 8.6 引擎路由规则

```swift
switch publication.kind {
case .text, .epubReflowable:
    if settings.writingMode == .vertical { → WebKitEngine }
    else if publication.containsRichContent { → WebKitEngine }   // SVG/MathML 检测
    else { → TextKitEngine }
case .epubFixedLayout: → WebKitEngine
case .comic: settings.isWebtoon ? .imageWebtoon : .imagePaged
case .webtoon: → .imageWebtoon
case .pdf: → .pdf
}
```

**切换引擎时必须**：保存当前 `Locator` → 销毁旧引擎 → 新引擎 `go(to: locator)`。位置不能丢。

---

## 9. 排版与阅读设置

### 9.1 设置模型

```swift
struct ReaderSettings: Codable, Equatable, Sendable {
    // 排版
    var fontFamily: ReaderFontFamily = .system     // .system / .serif / .songti / .kaiti / .custom(name)
    var fontSize: Double = 19                       // 12...32
    var lineHeightMultiple: Double = 1.8            // 1.2...2.4
    var paragraphSpacing: Double = 8                // 0...32
    var firstLineIndent: Int = 2                    // 0...4 字符
    var letterSpacing: Double = 0                   // -0.5...2
    var horizontalPadding: Double = 24              // 12...64
    var verticalPadding: Double = 16
    var justify: Bool = true
    var hyphenation: Bool = false
    var writingMode: WritingMode = .horizontal      // .horizontal / .vertical

    // 主题
    var themeName: String = "paper"                 // 语义名
    var followSystemAppearance: Bool = true

    // 翻页
    var pageTurnAnimation: PageTurnAnimation = .slide
    var tapZonePreset: TapZonePreset = .standard    // 左中右三分
    var volumeKeyPaging: Bool = false

    // 漫画
    var comicReadingDirection: ReadingProgression = .ltr
    var comicSpreadMode: SpreadMode = .auto         // .single / .auto / .double
    var isWebtoon: Bool = false
    var cropMargins: Bool = false

    // 系统
    var keepScreenOn: Bool = true
    var showProgressInChrome: Bool = true
}
```

### 9.2 字号与 Dynamic Type 的关系（容易做错）

- **阅读正文的字号由用户单独控制**，不跟随系统 Dynamic Type 的 `.body`（否则系统字号调大后一页只有两行字）。
- 但**工具栏、菜单、设置面板**必须完全跟随 Dynamic Type。
- 阅读正文提供「跟随系统字号」开关（默认关），开启时以系统 `.body` 为基准做缩放。
- 最小字号 12pt，最大 32pt。超过时提示"再大建议使用系统缩放"。

### 9.3 字体

- 内置：系统字体（`-apple-system` / `PingFang SC`）、宋体（`Songti SC`）、楷体（`Kaiti SC`）、仿宋（`STFangsong`）、苹方（`PingFang SC`）。
- 自定义：允许用户导入 `.ttf` / `.otf`，用 `CTFontManagerRegisterFontsForURL(_:scope:.persistent)` 注册。
- **字体注册失败必须降级到系统字体并提示**，不能白屏。
- 字体族切换后必须重新分页（排版指纹变化）。

### 9.4 排版指纹（分页缓存的关键）

```swift
struct TypographyProfile: Hashable, Codable, Sendable {
    var fontFamily: String
    var fontSize: Double
    var lineHeightMultiple: Double
    var paragraphSpacing: Double
    var firstLineIndent: Int
    var letterSpacing: Double
    var horizontalPadding: Double
    var verticalPadding: Double
    var pageWidth: Double      // 取整到 0.5pt
    var pageHeight: Double
    var writingMode: WritingMode
    var language: String

    var cacheKey: String { /* 稳定 hash，如 SHA256 前 16 位 */ }
}
```

分页缓存路径：`Caches/Pagination/<bookID>/<chapterID>/<cacheKey>.pageindex`

- 缓存命中 → 直接读取，打开速度 < 50ms。
- 缓存未命中 → 分页 → 写入。
- 缓存总量超过 200MB → LRU 清理（按书籍最后打开时间）。

---

## 10. 阅读交互

### 10.1 沉浸模式

- 进入阅读器默认：工具栏隐藏，正文全屏。
- 点击中央区域 → 显示顶部工具栏 + 底部进度条（`safeAreaBar` + Liquid Glass）。
- 再次点击中央 / 点击正文 / 3 秒无操作 → 隐藏。
- **工具栏显示/隐藏不得改变正文排版**（不能因为工具栏出现而压缩正文，否则每次点击都重排）。用 `safeAreaBar` 的浮层模式，或让正文始终按"工具栏隐藏时的高度"排版。

### 10.2 顶部工具栏

- 左侧：返回（`.cancellationAction`）、目录（`list.bullet`）
- 中间：书名（截断，不换行）
- 右侧：搜索、标注列表、更多菜单（`Menu`）

### 10.3 底部工具条

- 进度条（可拖动）：`Slider` 或自建，拖动时显示「第 X 章 · 32%」
- 上一章 / 下一章
- 阅读设置（`textformat.size`）
- 主题切换（快捷循环日/夜/护眼）

### 10.4 目录面板（TOCPanel）

- iPhone：`.sheet` + `presentationDetents([.medium, .large])`
- iPad：`.inspector` 或 `NavigationSplitView` 的 sidebar
- 支持章节搜索、当前章节高亮、已读标记
- 大目录（>500 章）：`List` + 懒加载，禁止一次性构建所有行

### 10.5 阅读设置面板

- 用 `.sheet` + `presentationDetents([.height(360), .large])`
- 字号用 `Slider` + 步进按钮（A- / A+）
- 行距、段距、边距用 `Slider`
- 字体族用横向 `ScrollView` 的字体预览卡片
- 主题用 4 个色块（日间/夜间/羊皮纸/护眼）
- **所有调整实时预览**（正文同步变化），关闭面板后保留

### 10.6 手势

| 手势 | 行为 |
|---|---|
| 单击左 1/4 | 上一页 |
| 单击中 1/2 | 显示/隐藏工具栏 |
| 单击右 1/4 | 下一页 |
| 左右滑 | 翻页 |
| 长按文字 | 选词 → 菜单（高亮/笔记/复制/搜索） |
| 双指捏合（漫画） | 缩放 |
| 双击（漫画） | 缩放 2x / 复位 |
| 音量键（可选） | 翻页 |

**冲突处理**：选词态下禁用翻页手势；缩放态下禁用翻页手势。

### 10.7 状态恢复

- 用 `SceneStorage` / SwiftData 存 `(bookID, Locator)`。
- App 被系统杀死后重启 → 回到书架 → 点书 → 回到上次位置。
- **必须在 `scenePhase == .background` 时立即落盘**，不能只依赖定时保存。

---

## 11. UI / Liquid Glass 规范

### 11.1 功能层 vs 内容层

| 层 | 元素 | 样式 |
|---|---|---|
| 功能层 | 顶部工具栏、底部进度条、Tab、菜单、Sheet、浮动按钮 | 系统 Liquid Glass（原生组件自动获得） |
| 内容层 | 正文、漫画图像、书架卡片、列表行 | 语义色 / 标准材质 / 图片 |

**禁止**：给书架卡片、列表行、正文背景加 `.glassEffect()`。

### 11.2 书架

- `NavigationStack` + `ScrollView` + `LazyVGrid`（自适应列：`GridItem(.adaptive(minimum: 120))`）
- 封面卡片：`ConcentricRectangle()` 或 `.rect(cornerRadius: 12)`，阴影极轻
- 封面加载：ImageIO 降采样到卡片尺寸，`NSCache`
- 空状态：`ContentUnavailableView`（"书架空空如也" + 导入按钮）
- 搜索：`.searchable`，`ContentUnavailableView.search` 处理无结果
- 排序/筛选：`Menu`（最近阅读 / 添加时间 / 标题 / 作者）
- 分组：按「在读 / 未读 / 已读完」或自定义书单（第二期）

### 11.3 导航

```swift
TabView(selection: $selectedTab) {
    Tab("书架", systemImage: "books.vertical.fill", value: .library) { LibraryView() }
    Tab("书单", systemImage: "square.stack.fill", value: .collections) { CollectionsView() }
    Tab("统计", systemImage: "chart.bar.fill", value: .stats) { StatsView() }
    Tab("设置", systemImage: "gearshape.fill", value: .settings) { SettingsView() }
}
.tabViewStyle(.sidebarAdaptable)   // iPad 自动变侧栏
```

- 打开书籍：`navigationDestination(item:)` 或 `.fullScreenCover`（阅读器推荐全屏）
- iPad 上阅读器也全屏，不用分栏（阅读需要最大画布）

### 11.4 颜色与主题

```swift
struct ReaderTheme: Sendable {
    let name: String
    let background: Color       // 内容层背景
    let text: Color
    let secondaryText: Color
    let accent: Color
    let chromeTint: Color       // 功能层强调色（克制）

    static let paper = ReaderTheme(...)     // #F7F3E8 / #2B2B2B
    static let night = ReaderTheme(...)     // #121212 / #C8C8C8
    static let pureBlack = ReaderTheme(...) // #000000 / #B0B0B0（OLED）
    static let sepia = ReaderTheme(...)     // #F0E2C8 / #3A2E1F
    static let green = ReaderTheme(...)     // #CCE8CF / #22302A
}
```

- 主题色必须是**语义定义**，不是散落的 hex。
- 每个主题必须满足 WCAG AA 对比度（正文 ≥ 4.5:1）。
- 夜间主题必须考虑 OLED 纯黑选项。
- 跟随系统外观时，在 `light`/`dark` 间切换对应主题。

### 11.5 动画

- 工具栏显隐：`opacity` + `offset`，180ms，`easeOut`
- 翻页：见 §8.2.6
- Sheet 弹出：系统默认
- **Reduce Motion 开启时**：翻页改瞬切/淡入，工具栏显隐改纯 opacity

---

## 12. 书架与书库

### 12.1 导入

- 入口：书架右上角 `+`（`.primaryAction`）→ `Menu`：
  - 从「文件」导入（`.fileImporter`，`allowedContentTypes` 覆盖所有支持格式 + `.folder`）
  - 从相册导入（漫画单页 → 打包为 CBZ）
  - 从剪贴板导入（文本）
- 多选导入，显示进度（`ProgressView` + 文件名）
- 导入后自动解析元数据、生成封面（EPUB 封面 / 漫画首图 / TXT 用标题生成占位封面）

### 12.2 安全范围书签

```swift
// 导入时
guard url.startAccessingSecurityScopedResource() else { throw ImportError.accessDenied }
defer { url.stopAccessingSecurityScopedResource() }
try FileManager.default.copyItem(at: url, to: sandboxURL)

// 若需长期引用外部目录（如监听文件夹）
let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
```

- **导入即复制**到沙盒，不长期持有外部引用（避免 iCloud 文件被移走后书打不开）。
- 大文件（>500MB 漫画）复制时显示进度，支持取消。

### 12.3 删除

- 删除书籍 = 删除 SwiftData 记录 + 沙盒目录 + 分页缓存 + 图片缓存。
- 用 `.confirmationDialog` 二次确认，文案说明"将同时删除阅读进度与笔记"。

---

## 13. 标注、书签、笔记

### 13.1 高亮

- 选词 → 菜单（`.highlight` / `.underline` / `.note` / 复制 / 搜索 / 分享）
- 高亮颜色用语义名（`yellow` / `green` / `blue` / `pink`），实际色值随主题变化
- 渲染：`addRenderingAttribute`，不修改文本
- 跨页选区：TextKit 2 原生支持，但需要处理「选到章节边界」→ 限制在单章内

### 13.2 笔记

- 高亮后追加笔记 → 弹出 `sheet` 输入
- 笔记面板：按章节分组，可跳转、编辑、删除
- 导出：Markdown / JSON

### 13.3 书签

- 单点书签（当前 Locator）
- 书签列表按时间倒序，可跳转

### 13.4 数据一致性

- 标注的 `Locator` 必须包含 `text.highlight`（用于重定位）
- 删除章节文件不会发生（章节文件只读）
- 换字体后，标注位置通过 `text.highlight` 重新匹配

---

## 14. 持久化

### 14.1 SwiftData 模型

```swift
@Model
final class BookEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    var kindRaw: String
    var formatExtension: String
    var relativePath: String          // 相对 Books/ 的路径
    var coverPath: String?
    var totalCharacters: Int
    var chapterCount: Int
    var addedAt: Date
    var lastOpenedAt: Date?
    var detectedEncoding: String?
    var isFinished: Bool

    @Relationship(deleteRule: .cascade) var progress: ProgressEntity?
    @Relationship(deleteRule: .cascade) var annotations: [AnnotationEntity]
    @Relationship(deleteRule: .cascade) var bookmarks: [BookmarkEntity]
    @Relationship(deleteRule: .cascade) var readingSettings: SettingsEntity?
}

@Model
final class ProgressEntity {
    var locatorJSON: Data            // Locator 编码
    var totalProgression: Double
    var updatedAt: Date
}

@Model
final class AnnotationEntity {
    @Attribute(.unique) var id: UUID
    var locatorJSON: Data
    var selectedText: String
    var styleRaw: String
    var colorName: String?
    var note: String?
    var createdAt: Date
}
```

**约束**：
- 不存章节正文。
- 不存大段 HTML。
- `selectedText` 上限 2000 字（超出截断并记录偏移）。
- 所有 `Data` 字段存 JSON 编码的 `Locator`，不要拆成十几个列。

### 14.2 文件布局

```
<Application Support>/
├── Books/
│   └── <bookID>/
│       ├── source.cbz              // 原始文件（漫画保留原包）
│       ├── extracted/              // EPUB 解压目录 / CBR 解压目录
│       ├── meta.json
│       ├── cover.jpg
│       ├── chapters/               // TXT 章节文件
│       └── index.json
└── UserFonts/
    └── custom.ttf

<Caches>/
├── Pagination/<bookID>/<chapterID>/<typographyKey>.pageindex
├── Images/<bookID>/<entryHash>.thumb
└── Exports/
```

- `Books/` 排除 iCloud 备份（`URLResourceValues.isExcludedFromBackup = true`），避免用户 iCloud 空间被撑爆。
- 分页缓存放 `Caches/`，系统可回收，我们的 LRU 也管理它。

### 14.3 迁移

- 每个 `VersionedSchema` 变更必须写 `MigrationPlan`。
- 禁止用"删库重建"处理迁移（会丢用户笔记）。

---

## 15. 文件导入与安全

### 15.1 格式嗅探（不信任扩展名）

```swift
enum FormatSniffer {
    static func sniff(url: URL) -> DetectedFormat?
}
```

- 读前 16 字节魔数：
  - `PK\x03\x04` → ZIP 系（可能是 CBZ / EPUB / 普通 ZIP）
  - `%PDF` → PDF
  - `Rar!\x1A\x07` → RAR4；`Rar!\x1A\x07\x01\x00` → RAR5
  - `7z\xBC\xAF\x27\x1C` → 7z
  - 其余 → 尝试文本探测
- ZIP 系再细分：有 `mimetype` 文件且内容为 `application/epub+zip` → EPUB；有 `META-INF/container.xml` → EPUB；否则按图片数量判为 CBZ。
- **扩展名与魔数冲突时，以魔数为准**，并给用户提示。

### 15.2 解压安全（必须实现）

1. **Zip Slip 防护**：解压每个 entry 前，把目标路径 `standardizedFileURL`，断言其 `path` 以目标目录 `path` 为前缀。不满足则跳过并记录。
2. **Zip Bomb 防护**：累计解压大小超过 `ExtractionLimits.maxTotalSize` 立即中止；单条目压缩比超过 200:1 且解压后 > 100MB 则中止。
3. **条目数上限**：超过 `maxEntryCount` 中止。
4. **符号链接**：拒绝解压 `symlink` 类型条目。
5. **嵌套深度**：ZIP 内再套 ZIP 不自动递归解压（漫画包内嵌包视为普通文件）。
6. **解压到临时目录再原子移动**：避免半成品污染。

### 15.3 文件名编码

- ZIP 规范未定义文件名编码（历史遗留）。UTF-8 flag（bit 11）为 0 时通常是 CP437 或本地编码。
- 国漫常见 GBK。处理链：UTF-8 严格 → GB18030 → CP437。
- 若 ZIPFoundation 无法拿到原始字节，需要自己解析中央目录（或用 libarchive 的 `headerEncoding` 选项）。

### 15.4 EPUB 脚本安全

- EPUB 内容**不可信**。
- WKWebView 加载前：注入脚本移除所有 `<script>`、`on*` 事件属性、`<iframe>`、`<object>`、`<embed>`。
- 用 `WKContentRuleList` 阻断所有非本地资源请求（`http://`、`https://` 一律 block）。
- 禁止 `window.open`、`alert`、`prompt`（`WKUIDelegate` 返回 nil）。
- 禁止导航到外部 URL（`decidePolicyFor` 中对非 `file://` 的导航一律 `cancel`）。
- **不实现** EPUB 的远程资源加载（在线字体、外链图片）。

### 15.5 隐私

- 无网络权限（第一期完全不联网）。
- 不收集任何数据。
- 不接入分析 SDK。

---

## 16. 性能预算

| 指标 | 目标 | 测量方式 |
|---|---|---|
| 冷启动到书架可见 | < 800ms | Instruments App Launch |
| 打开 TXT（3MB）到首屏 | < 300ms | 自定义 signpost |
| 打开 EPUB（5MB）到首屏 | < 600ms | 同上 |
| 翻页（文字） | < 8ms（120Hz 下不掉帧） | Instruments Animation Hitches |
| 翻页（漫画，已缓存） | < 16ms | 同上 |
| 首次解码一页漫画（3000×4000） | < 120ms | signpost |
| 分页 10 万字章节 | < 150ms | signpost |
| 字体切换（重新分页） | < 400ms（当前章） | signpost |
| 内存峰值（文字书） | < 150MB | Instruments Allocations |
| 内存峰值（漫画） | < 350MB | 同上 |
| 滚动条漫 | 稳定 60fps / ProMotion 自适应 | Core Animation |

**硬性规则**：
- 任何在主线程超过 16ms 的同步操作都是 bug。
- 图片解码、文件读取、分页计算**必须**离开主线程。
- 用 `os_signpost` 给关键路径打点，方便 Instruments 定位。

---

## 17. 无障碍与本地化

### 17.1 无障碍

- 正文：`isAccessibilityElement = true`，`accessibilityLabel` = 当前页文本（分块），`accessibilityValue` = "第 3 章，共 12 页，第 1 页"
- 翻页手势需有 VoiceOver 替代：`accessibilityScroll(_:)` 实现
- 工具栏按钮：全部有 `accessibilityLabel`，图标按钮不省略文字标签（用 `.labelStyle(.iconOnly)` 但保留 label）
- 进度条：`accessibilityValue` 为百分比 + 章节名
- 对比度：所有主题正文 ≥ 4.5:1
- `Differentiate Without Color`：高亮除颜色外还有下划线或图标
- Reduce Motion：见 §11.5
- Reduce Transparency：功能层自动退化（系统处理，但自定义玻璃元素需检查）

### 17.2 本地化

- 字符串资源用 `Localizable.xcstrings`（String Catalog）。
- 第一期：简体中文 + 英文。
- 所有 `Text` 用字面量插值，禁止字符串拼接。
- 日期/数字用 `Text(_:format:)` 或 `Date.FormatStyle`。
- 书名、作者不做翻译。
- 章节标题中的数字按 locale 显示（可选）。

---

## 18. 测试与验收

### 18.1 单元测试（必须有）

| 模块 | 用例 |
|---|---|
| `TextEncodingDetector` | GBK / GB18030 / UTF-8 / UTF-8-BOM / UTF-16LE / Big5 / Shift-JIS 各 1 份，断言解码正确 |
| `ChapterSplitter` | 标准中文标题、无章节文本、误判防护（数字列表）、超长章节 |
| `LocatorResolver` | charOffset 精确、highlight 模糊（差 1 字）、progression 兜底、跨排版恢复 |
| `Paginator` | 给定文本 + 尺寸，页数稳定；同一输入两次分页结果一致 |
| `ProgressMapper` | 章节偏移 → totalProgression 的边界（首/末章、空章） |
| `ExtractionLimits` | zip bomb 样本被拒绝；zip slip 样本被拒绝 |
| `FormatSniffer` | 扩展名伪装（`.cbz` 实际是 PDF）被正确识别 |
| `SpreadResolver` | 跨页图识别、双页模式下页码映射 |

### 18.2 UI 测试（关键路径）

- 导入 TXT → 打开 → 翻 3 页 → 退出 → 重进 → 位置一致
- 切换字号 → 位置不丢（偏差 < 1 个字符）
- 切换主题 → 不重新分页（用 signpost 断言无分页调用）
- 导入 CBZ → 打开 → 翻页 → 进度正确
- iPad 分屏拖拽改变宽度 → 文字重新分页 → 位置不丢

### 18.3 性能测试

- 用 XCTest 的 `measure(metrics:)` 测分页、解码、打开。
- 建立 10 本测试书语料（大 TXT、图文 EPUB、FXL EPUB、CBZ、PDF）。

### 18.4 验收清单（每个里程碑）

```
□ xcodebuild build 零警告
□ 该里程碑的单元测试全绿
□ 真机（iPhone + iPad）各跑一遍关键路径
□ Instruments 无内存泄漏（Leaks）
□ 无主线程超时（Hang）
□ VoiceOver 能读出当前页
□ 深色模式、超大字号下不破版
```

---

## 19. 里程碑

### M0：工程骨架（1~2 天）

- 创建 Xcode 工程，部署目标 iOS 26，Swift 6，Strict Concurrency
- 目录结构按 §4.2 建立
- `AppContainer` 依赖注入根
- SwiftData 模型 + 空书架
- 一个能编译、能跑的 `#Preview`

**验收**：App 启动显示空书架 + `ContentUnavailableView`。

### M1：TXT 阅读闭环（3~5 天）——**最重要**

- `TextEncodingDetector` + 测试
- `ChapterSplitter` + 测试
- `TextPublicationParser`（TXT）
- `TextKitEngine` 最小可用：单章分页、翻页、进度
- `ReaderView` + 沉浸模式 + 顶部/底部工具栏（Liquid Glass）
- 阅读设置面板（字号、行距、主题）
- 进度持久化 + 恢复

**验收**：
- 导入 5MB GBK TXT，无乱码，目录正确
- 翻页流畅（真机 120Hz 不掉帧）
- 切换字号后位置偏差 < 1 字符
- 杀进程后重进，位置一致

### M2：EPUB 可重排 + 排版完善（4~6 天）

- 接入 Readium（`ReadiumShared` + `ReadiumStreamer`）
- `EPUBPublicationParser`（解压 + XHTML → NSAttributedString）
- 图片/脚注/链接处理
- 排版完善：首行缩进、段间距、两端对齐、标点处理
- 分页缓存（`TypographyProfile` + `PageIndexCache`）
- 目录面板、章节跳转
- 全书搜索

**验收**：
- 打开 5MB EPUB < 600ms（二次打开 < 100ms，缓存命中）
- 图文混排正确，图片不超页
- 搜索能定位并高亮

### M3：漫画（CBZ / 文件夹）（4~6 天）

- `ZIPArchiveReader`（ZIPFoundation）
- `ComicPublicationParser`
- `ComicPagedEngine`：降采样、预取、缩放、跨页识别、RTL
- `ComicWebtoonEngine`
- 图片缓存 + 内存压力处理
- 漫画阅读设置（方向、双页、条漫）

**验收**：
- 300 页 CBZ 快速滑动 200 次不 OOM
- 日漫 RTL 方向正确
- iPad 横屏双页模式正确
- 内存峰值 < 350MB

### M4：标注与笔记（3~4 天）

- 选词交互（TextKit 2 selection）
- 高亮/下划线/笔记
- 标注列表、跳转、编辑、删除
- 书签
- 导出 Markdown

**验收**：
- 跨段落选词正确
- 换字号后标注位置正确
- 笔记能导出

### M5：固定布局 EPUB + PDF + 更多压缩格式（4~5 天）

- `WebKitEngine`（FXL、SVG、MathML）
- `PDFEngine`（PDFKit）
- `LibArchiveReader`（RAR / RAR5 / 7z）
- EPUB 脚本安全加固

**验收**：
- FXL EPUB 显示与桌面阅读器一致
- PDF 夜间模式可读
- CBR / CB7 能打开

### M6：竖排、FB2、打磨（5~7 天）

- 竖排（WebKit CSS `writing-mode`）
- FB2 解析
- 全量无障碍审计
- 性能调优（Instruments）
- 本地化（英文本地化）
- App 图标（Icon Composer 分层图标）

**验收**：全部 §18.4 清单通过。

---

## 20. 编码规范与禁用清单

### 20.1 命名

- 类型：`UpperCamelCase`；方法与属性：`lowerCamelCase`
- 协议：能力用 `-able` / `-ing`，角色用名词（`PublicationParser`）
- 一个文件一个主要类型（小型辅助类型可同文件）
- 测试文件命名 `<TypeName>Tests.swift`

### 20.2 并发

- 所有 UI 相关类型标 `@MainActor`
- 纯数据模型标 `Sendable`
- 用 `async/await`，不用 completion handler（桥接第三方时除外）
- 用 `Task` 而非 GCD（TextKit 的专属队列除外）
- `Task` 必须可取消：长任务里检查 `Task.isCancelled`

### 20.3 禁用 API 清单

| 禁用 | 替代 |
|---|---|
| `UIScreen.main` | `traitCollection.displayScale` / `onGeometryChange` |
| `foregroundColor()` | `foregroundStyle()` |
| `cornerRadius()` | `clipShape(.rect(cornerRadius:))` |
| `accentColor()` | `tint()` |
| `tabItem()` | `Tab` |
| `navigationBarLeading/Trailing` | `.topBarLeading` / `.topBarTrailing` / 语义 placement |
| `onChange(of:) { }`（单参数） | `onChange(of:) { old, new in }` |
| `NavigationView` | `NavigationStack` / `NavigationSplitView` |
| `GeometryReader`（仅为了读尺寸） | `onGeometryChange` |
| `DispatchQueue.main.asyncAfter` 做动画链 | `withAnimation(_:completion:)` |
| `AnyView` | 泛型 / `Group` / 提取 struct |
| `Color.cgColor` | `Color.resolve(in:)` |
| `UIImpactFeedbackGenerator` | `sensoryFeedback()` |
| `.ultraThinMaterial` 冒充玻璃 | 原生 `.glassEffect()` |
| `UIImage(data:)` 直接解码大图 | `CGImageSourceCreateThumbnailAtIndex` |

### 20.4 注释

- 公开 API 必须有 `///` 文档注释
- 复杂算法（分页、重定位、跨页识别）必须写清思路与边界
- 线程约束必须注释（"必须在 xxx 队列调用"）
- 不写"// TODO: 实现"然后交付

---

## 21. 交付物

每个里程碑交付：

1. **可编译的工程**（`xcodebuild build` 零警告）
2. **变更说明**：改了什么、为什么、影响哪些模块
3. **验证报告**：跑了哪些测试、真机结果、未验证项（必须明说）
4. **已知问题清单**

最终交付：

1. 完整 Xcode 工程
2. 架构文档（本文档 + 实际实现差异说明）
3. 测试语料库（各格式样本各 3 份）
4. 性能基线报告

---

## 22. 给代理的执行流程

### 22.1 每次开工前

1. 读 §2「已核实事实」——确认没有引入禁用依赖
2. 读 §3「硬性约束」——确认没有违反架构约束
3. 读当前里程碑的验收标准
4. **检查现有代码**：不要重复实现已有能力，不要改无关文件

### 22.2 实现时

1. 先写协议/模型，再写实现
2. 每个新类型配一个 `#Preview` 或单元测试
3. 涉及渲染的改动，先在模拟器验证编译，再在真机验证性能
4. 遇到 SDK API 不确定：**查文档，不要猜**。猜错会浪费一轮编译

### 22.3 交付前

1. `xcodebuild build` 零警告
2. 跑该里程碑的测试
3. 对照 §18.4 验收清单逐项打勾
4. 明确列出「未验证项」

### 22.4 绝对不要做

- ❌ 引入白名单外的依赖
- ❌ 写 `#available(iOS 26, *)`（部署目标已经是 26）
- ❌ 用 SwiftUI 逐字渲染长文本
- ❌ 用 `UITextView` 做分页
- ❌ 用 TextKit 1 的多容器分页
- ❌ 给内容层加 `.glassEffect()`
- ❌ 手搓玻璃效果
- ❌ 把章节正文存进 SwiftData
- ❌ 用 `pageIndex` 作为持久化进度
- ❌ 用 `UIScreen.main`
- ❌ 在 `body` 里做排序/过滤/格式化
- ❌ 跳过真机性能验证就宣称"流畅"
- ❌ 在没跑通 M1 前开始 M2

---

## 附录 A：关键 API 速查

### A.1 TextKit 2

| API | 用途 |
|---|---|
| `NSTextContentStorage` | 文本数据源 |
| `NSTextLayoutManager` | 布局管理器（核心） |
| `NSTextContainer` | 可视区域尺寸 |
| `NSTextLayoutFragment` | 布局碎片（最小缓存单元） |
| `NSTextViewportLayoutController` | 视口驱动，按需布局 |
| `enumerateTextLayoutFragments(from:options:using:)` | 遍历 fragment（分页用） |
| `enumerateTextSegments(in:type:options:using:)` | 遍历行/选择段（细化断点用） |
| `addRenderingAttribute(_:value:for:)` | 叠加渲染属性（高亮，不重排） |
| `NSTextSelectionNavigation` | 选词导航 |
| `ensureLayout(for:)` | 强制布局指定范围 |

### A.2 SwiftUI iOS 26

| API | 用途 |
|---|---|
| `Tab` / `TabView` | 值驱动 Tab |
| `.tabViewStyle(.sidebarAdaptable)` | iPad 侧栏自适应 |
| `.glassEffect(_:in:)` | Liquid Glass（仅功能层） |
| `GlassEffectContainer(spacing:)` | 玻璃元素合并 |
| `.glassEffectID(_:in:)` | 玻璃形变过渡 |
| `.buttonStyle(.glass)` / `.glassProminent` | 玻璃按钮 |
| `safeAreaBar(edge:alignment:spacing:content:)` | 自定义浮层工具条 |
| `ConcentricRectangle()` | 同心圆角 |
| `backgroundExtensionEffect()` | 侧栏背景延展 |
| `.scrollEdgeEffectStyle(_:for:)` | 滚动边缘效果 |
| `.font(.body.scaled(by:))` | 自定义字号缩放 |
| `onGeometryChange(for:of:action:)` | 尺寸监听 |
| `ContentUnavailableView` | 空状态 |
| `.searchable` + `searchSuggestions` | 搜索 |

### A.3 图像

| API | 用途 |
|---|---|
| `CGImageSourceCreateWithData` | 创建图像源 |
| `CGImageSourceCreateThumbnailAtIndex` | 降采样解码 |
| `kCGImageSourceThumbnailMaxPixelSize` | 目标像素尺寸 |
| `kCGImageSourceCreateThumbnailWithTransform` | 自动应用 EXIF 旋转 |
| `NSCache` | 解码图/原始数据缓存 |

### A.4 压缩

| API | 用途 |
|---|---|
| `Archive(url:accessMode:)`（ZIPFoundation） | 打开 ZIP/CBZ |
| `archive[path]` | 按路径取条目 |
| `archive.extract(entry, to:)` | 解压单条目 |
| `FileManager.unzipItem(at:to:)` | 整包解压（EPUB 导入用） |
| `ArchiveReader().entries(at:)`（libarchive-swift） | 列出 RAR/7z 条目 |
| `ArchiveReader().data(forEntryPath:in:)` | 读单条目 |

---

## 附录 B：参考资料

### B.1 已核实（本次检索确认）

| 来源 | 内容 | 链接 |
|---|---|---|
| Readium Swift Toolkit | BSD-3-Clause；模块 `ReadiumShared` / `ReadiumStreamer` / `ReadiumNavigator` / `ReadiumOPDS` / `ReadiumLCP`；支持 EPUB reflowable/fixed、PDF、CBZ、Divina；**CBR 不支持**；SPM 集成 | https://github.com/readium/swift-toolkit |
| Readium 文档：Preferences | `EPUBPreferences` / `EPUBDefaults` / `PreferencesEditor` / `submitPreferences`；`Codable` 可序列化 | https://readium.org/swift-toolkit/latest/documentation/readium/preferences/ |
| Readium 文档：Decorations | `Decoration` / `HTMLDecorationTemplate` / `addRenderingAttribute` 等价能力 | https://readium.org/swift-toolkit/latest/documentation/readium/decorations/ |
| Apple: `NSTextLayoutManager` | TextKit 2 核心类，`enumerateTextLayoutFragments`、`addRenderingAttribute`、`textViewportLayoutController` 等 | https://developer.apple.com/documentation/UIKit/NSTextLayoutManager |
| TextKit 2 长文本分页架构（掘金） | 单页独立 LayoutManager + 页面池 + 字符区间分页 + LRU 缓存；明确 TK1 多容器模式不适用 TK2 | https://juejin.cn/post/7681991052950339584 |
| TextKit 2 实战（Aoede） | 单 `NSTextLayoutManager` 承载整章；渲染属性改色不触发重排；fragment 矩形可直接查询 | https://krisbaker.com/building/aoede/a-textkit-2-reader-for-the-scroll/ |
| Aidoku PR #904 | Kindle 风格分页文字阅读器：`NSLayoutManager` 分页、字符偏移持久化、滚动/分页进度同步 | https://github.com/Aidoku/Aidoku/commit/ad3595f |
| ZIPFoundation | MIT；基于 libcompression；`Archive` 随机访问、`unzipItem` 整包解压 | https://github.com/weichsel/ZIPFoundation |
| libarchive-swift | Swift 封装 libarchive；支持 7z / rar / rar5 / zip / cab / iso；RAR 只读；支持 `headerEncoding` 与 `automaticHeaderEncoding`（解决 GBK 文件名） | https://github.com/everpcpc/libarchive-swift |
| ComicReader（参考实现） | CBZ/CBR/CB7 解压组合：Zip + LzmaSDKObjC + UnrarKit | https://github.com/Flaviusns/ComicReader |

### B.2 需本地核实（`【待本地核实】`）

以下条目在本次检索中**未获得可靠来源**，实现前请用 Xcode 26 SDK 或 Apple 官方文档确认：

1. SwiftUI `WebView`（iOS 26）的完整 API 表面：初始化参数、`navigationDelegate` 支持、JS 注入能力。若能力不足，退回 `UIViewRepresentable` 包 `WKWebView`。
2. `scrollEdgeEffectStyle(_:for:)` 的完整枚举值（`.automatic` / `.soft` / `.hard` / `.hidden`？）。
3. `safeAreaBar` 的精确签名（`edge:` / `alignment:` / `spacing:` / `content:`）。
4. `.font(.body.scaled(by:))` 是否存在于 `Font` 还是仅 `Text`。
5. `GlassEffectContainer` 与 `.glassEffectID` 在 ScrollView 内的性能表现。
6. `PDFPageOverlayViewProvider` 在 iOS 26 的可用性与签名。
7. `libarchive-swift` 是否支持**随机访问**单条目（不整包解压）——影响 CBR 的按需加载策略。
8. `UnrarKit` 捆绑的 unrar 版本与 RAR5 支持情况，以及 RARLAB 许可对 App Store 发行的约束。
9. `ImageIO` 对 AVIF 的解码支持范围（iOS 26 应已支持，需实测）。
10. `CTFontManagerRegisterFontsForURL(_:scope:.persistent)` 在沙盒 App 中的实际行为（是否需要重启生效）。

### B.3 建议进一步查阅

- WWDC25: "Build a SwiftUI app with the new design" / "Meet Liquid Glass"
- WWDC25: "What's new in SwiftUI"
- WWDC24/25: "What's new in TextKit and text views"
- Readium 官方文档：https://readium.org/swift-toolkit/
- Apple HIG: https://developer.apple.com/design/human-interface-guidelines/
- EPUB 3.3 规范：https://www.w3.org/TR/epub-33/
- ComicInfo.xml schema：https://github.com/anansi-project/comicinfo

---

## 附录 C：风险登记册

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| TextKit 2 分页在超长章节下卡顿 | 中 | 高 | 章节虚拟分块（§7.2.2）；分页缓存；后台预分页 |
| 中文标点挤压/避头尾 TextKit 不支持 | 高 | 中 | 用 `NSParagraphStyle` 的 `lineBreakStrategy = .pushOut`；必要时自绘断行 |
| 竖排只能走 WebKit，体验不一致 | 高 | 中 | 竖排作为"实验性"功能，明确标注；或延后 |
| 国漫 ZIP 文件名 GBK 乱码 | 高 | 中 | libarchive 的 `headerEncoding`；或自解析中央目录 |
| EPUB 脚本安全 | 中 | 高 | §15.4 全套加固 |
| SwiftData 迁移丢数据 | 中 | 高 | 每版本写 `MigrationPlan` + 备份 |
| Readium 版本升级破坏 API | 中 | 中 | 锁定精确版本（`.exact("3.x.x")`），升级需评估 |
| 漫画内存爆炸 | 中 | 高 | 强制降采样 + LRU + 内存警告处理 |
| 进度丢失（用户投诉最严重） | 中 | 高 | Locator 双轨 + `scenePhase` 落盘 + 单测覆盖 |

---

*文档版本：1.0 · 适用于 iOS 26 / iPadOS 26 · Swift 6 · Xcode 26+*
