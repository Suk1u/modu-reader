# 墨读 · ModuReader

> iOS 26 原生阅读器。Swift 6 + SwiftUI（功能层）+ UIKit / TextKit 2（阅读内核）。

一款**仅支持 iOS 26 / iPadOS 26 及以上**的本地阅读器，深度使用 Liquid Glass 设计语言。

当前版本：**M1（TXT 阅读闭环）**

---

## 功能

- **TXT / Markdown 导入**：多编码自动探测（UTF-8 / UTF-16 / GB18030 / GBK / Big5 / Shift-JIS / EUC-JP / EUC-KR / Windows-1252）
- **智能章节切分**：中文章节标题（第 X 章 / 回 / 卷 / 话）、序章 / 番外、`Chapter N`、数字列表；带阈值保护防误判
- **TextKit 2 分页引擎**：按行精确切页，长段落不会被拦腰截断
- **沉浸式阅读**：全屏正文 + Liquid Glass 浮动工具栏，点击中央呼出
- **阅读设置**：5 种主题、6 种字体、字号 / 行距 / 段距 / 页边距 / 首行缩进实时预览
- **进度持久化**：字符级 Locator，换字号后位置不丢
- **iPad 适配**：`sidebarAdaptable` 侧栏、分屏与台前调度下自动重排

## 不支持（M2 以后）

EPUB、漫画（CBZ / CBR）、PDF、RAR / 7z、标注、笔记、竖排、FB2 / MOBI。

---

## 技术选型

| 层 | 技术 | 理由 |
|---|---|---|
| 功能层 | SwiftUI | 导航、工具栏、设置面板、书架 |
| 阅读画布 | UIKit + `UIViewRepresentable` | 长文本逐字渲染不能用 SwiftUI 视图树 |
| 文字引擎 | **TextKit 2**（`NSTextLayoutManager`） | 懒布局、字符级进度、中文排版可控 |
| 持久化 | SwiftData + 文件系统 | 元数据入库，正文落地为文件 |
| 第三方依赖 | **零** | M0/M1 不需要任何外部库 |

### 为什么不用 WKWebView 做文字引擎

| 维度 | TextKit 2 | WKWebView |
|---|---|---|
| 中文标点挤压 / 避头尾 | 可控 | 受 CSS 限制 |
| 分页断点 | 精确到行 | CSS multi-column 不可控 |
| 进度精度 | 字符偏移 | 滚动比例，跨排版漂移 |
| 内存 | 单进程 | 多 WebContent 进程 |

WKWebView 留给 M5 的固定布局 EPUB 与竖排。

### 分页算法

```
章节文本 → NSTextContentStorage → NSTextLayoutManager → NSTextContainer(页面尺寸)
  ↓ enumerateTextLayoutFragments
  ↓ 整块放得下 → 累加高度
  ↓ 放不下 → enumerateTextSegments(in: fragmentRange, type: .standard) 逐行切
  ↓ 输出 [PageSlice{ range, pageIndex }]
```

- 每页只持有自己的 `NSAttributedString` 子串（内存可控）
- 分页在专用串行队列执行，跨队列只传 `Sendable` 值类型
- 主题切换只改渲染属性，**不重新分页**

---

## 构建

### 本地构建（需要 macOS + Xcode 26）

```bash
brew install xcodegen
xcodegen generate
open ModuReader.xcodeproj
```

### 云构建（GitHub Actions）

推送 `main` 分支即触发，产出**未签名 IPA**：

```
Actions → Build Unsigned IPA → Artifacts → ModuReader-unsigned-ipa
```

### 安装

未签名 IPA 需要用侧载工具重签：

- **Sideloadly**（Windows / macOS）
- **AltStore / SideStore**（需要 Apple ID）
- **TrollStore**（仅限特定系统版本）

---

## 工程结构

```
ModuReader/
├── App/              应用入口、依赖注入根
├── Domain/           Publication / Locator / Chapter（纯 Swift，无 UIKit）
├── Services/
│   ├── Encoding/     编码探测
│   ├── Parsing/      章节切分、TXT 解析
│   ├── Import/       格式嗅探、导入流程
│   └── Storage/      沙盒文件布局
├── Render/
│   ├── RenderEngine  引擎协议
│   └── TextKit/      分页器、页面视图、页面池、引擎
├── Features/
│   ├── Library/      书架
│   ├── Reader/       阅读界面、会话、工具栏、设置、目录
│   └── Settings/     全局设置
├── DesignSystem/     主题、排版
└── Persistence/      SwiftData 实体
```

---

## 开发约束

1. **Liquid Glass 只用于功能层**。正文、卡片、列表行禁止 `.glassEffect()`。
2. **禁止手搓玻璃**（`.ultraThinMaterial` + 渐变模拟）。
3. **正文不进数据库**，只存索引与元数据。
4. **Locator 是唯一位置真相**，禁止用页码持久化进度。
5. **禁止 `UIScreen.main`**，用 `traitCollection` / `onGeometryChange`。
6. **禁止 `AnyView`**。
7. 部署目标是 iOS 26，**不需要 `#available` 分支**。

运行静态检查：

```bash
python scripts/lint_swift.py
```

---

## 测试

```bash
xcodebuild test -project ModuReader.xcodeproj -scheme ModuReader \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```

覆盖：编码探测（10 例）、章节切分（12 例）、位置重定位（13 例）、分页器（10 例）。

---

## 许可

MIT
