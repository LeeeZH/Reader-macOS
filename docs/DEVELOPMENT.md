# Reader for macOS · 开发笔记

工程说明、实现细节和踩坑记录，面向要改代码的人。
只想安装和使用 → [返回 README](../README.md)。

本项目是 [binbyu/Reader](https://github.com/binbyu/Reader) 的 macOS 原生重写版（Apple Silicon / arm64）。
原版是纯 Win32 C/C++ 程序，macOS 上一行都不能直接编译。本项目的策略是
**算法与数据格式复用 + UI 与排版层原生重写**：编码识别、`FormatText` 规范化、
章节解析规则、`.cache.dat` 存档格式全部照搬原版语义，界面用 AppKit 重做。

---

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | macOS 13.0+ |
| 芯片 | Apple Silicon (arm64) |
| 工具链 | Xcode Command Line Tools 的 `swiftc`（**不需要完整 Xcode**） |
| 第三方依赖 | **零** |

检查工具链：

```bash
swiftc --version    # 应输出 Apple Swift version 6.x
```

---

## 怎么运行

### 终端

```bash
./build.sh        # 编译 → dist/Reader.app
./run.sh          # 编译并启动
./run.sh --console # 前台运行（能看到 stdout/stderr，排查崩溃用）
./test.sh         # 跑核心逻辑单测
```

`build.sh` 会自动生成 `compile_commands.json`（给 VSCode 用），
编译出 arm64 可执行文件，组装 `.app` 并做 ad-hoc 签名。

产物：`dist/Reader.app`，双击即可运行。

### 排查排版问题：离屏渲染成 PNG

不需要开窗口、不需要截图权限，直接把某一页渲染成图片，用来检查排版：

```bash
# 把样书第 1 页渲染出来（GBK 编码版，顺便验证解码）
./dist/Reader.app/Contents/MacOS/Reader --render-page samples/古文观止-GBK.txt /tmp/page.png

# 渲染第 3 页（页码从 0 开始）
./dist/Reader.app/Contents/MacOS/Reader --render-page samples/古文观止.txt /tmp/p3.png 2
```

输出还会带上这一页的字符区间（如 `本页偏移=709..1104`），
方便验证分页是否连续、有没有重叠或漏字。后续与 Windows 版做 parity 对比也用它。

也可以把各个窗口离屏渲染出来（都会塞演示数据）：

```bash
B=./dist/Reader.app/Contents/MacOS/Reader
$B --render-library   /tmp/library.png      # 阅读列表
$B --render-settings  /tmp/settings.png     # 显示设置
$B --render-bookmarks /tmp/bookmarks.png    # 书签面板
$B --render-chapter-search /tmp/search.png       # 章节搜索面板（第二个参数是查询词，可省略）
$B --dark --render-page 书.txt /tmp/dark.png 0   # 深色模式预览
$B --render-page 书.txt /tmp/mid.png 0 220       # 第 5 个参数 = 平滑滚动像素偏移
                                                  # （用来检查下一页有没有严丝合缝接上）
```

**导出分页表（parity / 回归用）**：

```bash
$B --dump-pages samples/古文观止.txt 420 660
# page  start  length  lines  chapter
# 0     0      382     24     1
# 1     382    390     24     1
# ...
```

这是方案里 R2 风险（CoreText 行高与 GDI `sz.cy` 不等 → 每页行数与原版不同）
唯一可靠的验证手段：拿同一本书在两个平台各导一份，逐页比对
`start` 和 `lines` 两列即可。`samples/golden-pages.tsv` 是当前实现的基准快照。

**关窗自检**（复现「点关闭按钮后意外退出」）：

```bash
$B --close-selftest samples/古文观止.txt
# 应当：打印"正在关闭主窗口" → 干净退出，退出码 0，且不产生崩溃报告
```

> 这个自检必须走 AppKit 的**真实启动路径**才有意义。手动调
> `applicationDidFinishLaunching` 复现不出来 —— 自动终止是靠
> `_scheduleCheckForTerminateAfterLastWindowClosed` 这个 run loop 定时器触发的。

**目录菜单自检**（长篇小说章节不能截断）：

```bash
$B --toc-selftest
# 造一本 3000 章的书，验「目录」是菜单栏一级菜单、列出全部章节、
# 打开时从当前章开始（前面的章节在顶部子菜单）、当前章打勾、
# 点当前章 / 最后一章能真的跳过去。退出码 0 表示全部通过。
```

> 背景：早期版本目录只列前 300 章，几千章的小说从第 301 章起在菜单里
> 根本点不到；后来虽然列全了，但每次点开都从第 1 章开始，读了两千章的人
> 还得滚半天。现在菜单在 `menuNeedsUpdate` 里按需重建（开书 / 改设置时
> 不建，点开「目录」才建），平铺部分从当前章开始，前面的章节倒序收在
> 顶部子菜单 —— 3000 章的书打开目录第一眼就是当前章，重建约 6ms。

**章节搜索自检**（章节号 / 中文数字 / 标题模糊）：

```bash
$B --chapter-search-selftest
# 造一本 1200 章的书（其中一章用中文数字 + 可跳字的普通标题），验：
#   · 阿拉伯数字 / 中文数字 / 全角数字 / 带「第…章」等写法都命中同一章
#   · 标题按顺序跳字也能模糊命中
#   · 空查询列出全书并选中当前章，回车跳转、面板自动收起
#   · 打字过程中面板不会自己关掉（搜索框不能绑随输入触发的 action）
# 退出码 0 表示全部通过。
```

**一键验证**（改动完跑一遍）：

```bash
./verify.sh     # 构建 → 单测 → 启动冒烟 → 窗口自检 → 关窗自检 → 启动前打开自检 → 目录菜单自检 → 章节搜索自检 → 离屏渲染
```

### VSCode

工作区已经配好，直接：

| 操作 | 快捷键 |
|---|---|
| 编译 | `⌘⇧B` |
| 运行 | `⌘⇧P` → `Tasks: Run Task` → `run` |
| 调试 | `F5`（LLDB，可打断点） |
| 跑测试 | `⌘⇧P` → `Tasks: Run Task` → `test` |
| 打开阅读列表 | 运行后按 `⌘L` |

**需要的扩展（你已经装好了）**：

| 扩展 | 作用 |
|---|---|
| `swiftlang.swift-vscode` | 语法高亮、补全、跳转、诊断（**必需**） |
| `llvm-vs-code-extensions.lldb-dap` | 断点调试（Swift 扩展的依赖，会自动带上） |

**原理**：Swift 扩展的后端是 `sourcekit-lsp`，它支持三种工程模式
（`swiftPM` / `compilationDatabase` / `buildServer`）。本项目**不用 SwiftPM**
（本机 SwiftPM 因 CLT 问题不可用），而是由 `build.sh` 生成 `compile_commands.json`，
让 sourcekit-lsp 以 `compilationDatabase` 模式工作 —— 补全、跳转、诊断照样有。

> ⚠️ 因此扩展里那些 SwiftPM 专属命令（`swift.run`、`swift.cleanBuild`、
> 依赖管理、测试浏览器）**不可用**，请用上面的 Tasks 代替。

---

## 实现状态

**M0 已完成**：工程骨架 + 构建系统 + 可运行的原生 App。
产品的功能视角见 [README](../README.md)，这里只记工程状态。

已实现：

**阅读**

- [x] 原生 arm64 `.app`，构建脚本一键出包
- [x] 打开 TXT（`⌘O` / **拖拽到窗口** / 拖到 Dock 图标 / 双击 / 命令行参数）
- [x] **编码自动识别**：UTF-8 / UTF-8 BOM / UTF-16LE / UTF-16BE / GB18030(GBK) / ANSI
- [x] **`FormatText` 规范化**（与原版逐条对齐 —— 见下文「为什么重要」）
- [x] **章节自动解析**：默认规则 / 关键字 / 正则三种模式
- [x] 自研分页引擎（字符区间 + 行数组模型），CoreText 渲染
- [x] 翻页：`→` `←` `空格` `PageUp/Down` / 鼠标点击
- [x] **平滑滚动**（默认开启）：按像素连续滚动 + 缓出动画，触控板直接用系统像素增量（含惯性），鼠标一格换算成固定距离
- [x] **逐行滚动**：`↑` `↓`，滚动量可设 1/2/3 行或整页（关掉平滑滚动后恢复原版的跳行手感）
- [x] **英文单词换行（Word wrap）**、**章前分页**、**翻页保留重叠行数**
- [x] 章节跳转：`⌘↑` 上一章 / `⌘↓` 下一章 / 菜单栏一级「目录」（列出全书章节，不设上限；打开时从当前章开始，前面的章节倒序收在顶部子菜单；当前章打勾，按需重建）
- [x] **章节搜索** `⌘J`：章节号（阿拉伯数字 / 中文数字 / 全角数字）和标题模糊匹配（按顺序跳字即可）；空查询列出全书并选中当前章，回车跳转；面板独立、不会在打字时误关
- [x] **设置窗口** `⌘,`：分 5 个标签页 —— **显示 / 翻页 / 窗口 / 章节 / 其他**，改动即时生效并保存
- [x] **鼠标按键逐键可配**：左键 / 右键各选「下一页 · 上一页 · 隐藏窗口 · 不动作」，左右一起按选「隐藏窗口 · 最小化窗口 · 不动作」。默认 左=下一页、右=上一页、双键=隐藏窗口
- [x] **深色模式**：默认跟随系统外观；一旦自定义颜色就自动改用自定义值
- [x] **书签面板** `⌘B`：列出当前书的书签（章节名 + 位置），可跳转 / 删除 / 全部清除
- [x] **窗口透明**：背景可调不透明度（10%~100%），**文字始终不透明**（比原版连字一起透明更易读）
- [x] **全局热键** `⌃⌥H`：一键隐藏 / 显示窗口（对应原版 Alt+H 的「老板键」）
- [x] **菜单栏图标**：显示/隐藏、打开文件、阅读列表、自动翻页、设置、退出
- [x] **自动翻页**：`⇧⌘A`，间隔 1~30 秒，可选每页翻一次或每次滚一行；**默认走平滑滚动**（整页滑过去而不是瞬移），关掉「平滑滚动」才变回瞬移（菜单、托盘、设置界面三处都能开关）
- [x] **沉浸模式** `⇧⌘B`：隐藏标题栏（含关闭/最小化/最大化按钮）和底部状态栏，正文铺满整窗；顶部留了一条透明拖动条，否则没法移动窗口。菜单、托盘、设置界面三处都能开关
- [x] **编辑模式** `⌘E`：可编辑的文本框覆盖层，退出时提示保存，**按原文件编码写回**
- [x] **取色器**：颜色面板支持透明度，可直接吸屏幕上的颜色

**阅读列表与存档**

- [x] **阅读列表（书架）窗口** `⌘L`：MRU 排序、**百分比进度**、打开、移除、清空、重新定位
- [x] 移除/清空正在读的那本时，**阅读界面同步回到空状态**
- [x] **进度自动记忆**：每本书独立，退出重进精确恢复（防抖 0.6s 落盘）
- [x] **书签存储**（每本最多 256 个，字符偏移）＋ 可查看可跳转
- [x] **`.cache.dat` 完整读写**：XOR 0x3a + JSON，47 键全 schema，原子写入
- [x] **与 Windows 版格式完全兼容**：能直接读原版存档，写出的文件结构与原版一致
- [x] **字体迁移**：存档里是 Windows 字体时渲染回退到苹方，但**不改写存档**
- [x] 存档损坏时自动备份并从空白开始（绝不静默丢数据）
- [x] **窗口尺寸/位置记忆**：主窗口存进 `.cache.dat` 的 `header.placement`
      （与**原版同字段**，Windows 上调好的位置迁移过来也能用）；
      阅读列表窗口用 macOS 原生的 frame autosave

**工程**

- [x] **应用图标**（矢量 SVG 源，自动生成 10 个尺寸的 `.icns`）
- [x] **381 项单元测试**（含分页回翻、逐行滚动、word wrap、章前分页、书架缓存、进度口径、深色模式）
- [x] **触控栏支持**：翻页 / 进度 / 换章（上/下一章）/ 书签 / 字号，两侧 popover 收纳长尾操作

尚未实现（按方案文档的路线图推进）：

- [ ] 全文搜索
- [ ] **章节标题独立字体/颜色**（`use_same_font` / `font_title` / `title_color`：字段已能读写，渲染层还没做双字体）
- [ ] 背景图片（拉伸/平铺）、无边框窗口（全屏已用系统 `⌘F` 实现）
- [ ] 在线书源（P2）、EPUB（P3，MOBI 建议放弃）

---

## 项目结构

```
Reader/
├── build.sh                  构建：swiftc → .app（并生成 compile_commands.json）
├── run.sh                    构建并运行
├── test.sh                   核心逻辑单测
├── compile_commands.json     自动生成，给 sourcekit-lsp 用（已 gitignore）
├── Resources/Info.plist      Bundle 配置
├── samples/古文观止.txt           样书（3 章，UTF-8）
├── samples/古文观止-GBK.txt       同一本样书的 GBK 编码版
├── docs/DEVELOPMENT.md       开发笔记（本文件）
├── docs/images/reading.png   README 用的界面截图
├── Tests/main.swift          单测入口
├── .vscode/                  tasks / launch / settings
└── Sources/
    ├── main.swift            入口
    ├── App/
    │   └── AppDelegate.swift 菜单、窗口、打开文件
    ├── Core/                 纯逻辑，不依赖 UI，可单测
    │   ├── Types.swift       默认值（数值照搬原版 Cache.cpp）
    │   ├── TextDecoder.swift 编码识别
    │   ├── TextNormalizer.swift  FormatText / GetLine  ← 兼容性关键
    │   ├── ChapterParser.swift   三种章节解析模式
    │   ├── ChapterSearch.swift   章节搜索（数字 / 中文数字 / 标题模糊）
    │   └── Book.swift        TXT 书籍模型
    ├── Layout/               排版计算
    │   ├── TextMetrics.swift 字体度量 + advance 缓存
    │   └── PageModel.swift   页/行/字符数据模型
    └── Views/
        ├── ReadingView.swift 自绘阅读视图 + 分页
        ├── TOCMenuContent.swift 目录菜单内容（全部章节 + 当前章定位）
        └── ChapterSearchWindow.swift 章节搜索面板（⌘J）
```

---

## 几个关键设计决策

### 1. 为什么不用 `NSTextView` / `CTFramesetter`

它们把「整篇文本 → 布局」交给系统，只暴露可见范围查询。
而阅读进度、书签、章节锚点**全部是字符偏移**，必须由我们自己保证
「翻到第 N 页时页首的字符偏移」是确定且可复现的。

所以：**CoreText 只提供「一个字符有多宽」和「怎么画」，断行与分页由 `ReadingView` 负责。**
一页 = 一个字符区间 + 一个行数组（`PageBox` / `LineBox` / `CharBox`）。

### 2. 为什么 `FormatText` 必须逐条复刻

`item_t.index`（阅读进度）与 `item_t.mark[]`（书签）存的是
**`FormatText` 处理之后**的 UTF-16 字符偏移 —— 不是页码、不是字节偏移。

`FormatText` 会删开头空行、把连续空行压到最多 1 行、规范化超长缩进。
这里任何行为偏差，都会让 Windows 版用户的进度和书签全部错位。
`Tests/main.swift` 里为它写了 9 项单测。

### 3. 一处有意修复原版的 bug

原版 `ParserChaptersDefault` 里，「楔子 / 序章」的判定条件是
`line_size > i + 2`，导致**只含「楔子」两字的行永远匹配不上**
（而且同一条件里的 `|| line_size <= i + 1` 与主条件互斥，是永不成立的死代码）。

本项目改为「后面是空白 或 正好在行尾」。
**这个修复不影响与 Windows 版的存档兼容性** —— 章节列表不会写入 `.cache.dat`，
每次打开都是重新解析的。

### 4. 「上一页」为什么是算出来的，不是翻页历史

第一版用「翻页历史栈」实现上翻——看似简单，但 `jump()`（目录跳章节、恢复阅读进度）
会清空历史，**导致跳转一次之后就再也翻不回去**。

现在改成真正的方向性算法：`pageEnd(s)`（从字符 s 排一页的结束位置）关于 s 单调不减，
所以二分即可。这里有个**很容易搞反的方向**：

| 规则 | 后果 |
|---|---|
| 取**最大**的 s 使 `pageEnd(s) <= 当前位置` ❌ | 页面断点落在**行**边界上，`pageEnd` 在一片行宽内是平坦的。取最大值会挑到平坦区间的末尾——那一页虽然也结束在当前位置，但它从更靠后开始，前面的内容被**跳过**，而且一直往前翻会提前卡死、回不到书首 |
| 取**最小**的 s 使 `pageEnd(s) >= 当前位置` ✅ | 这是能一页覆盖到当前位置的**最早**起点，保证不漏内容；且该页的结束位置正好等于当前位置，再按「下一页」能精确回到原处 |

实测单次回翻约 **1.3 ms**（书长 1.1 万字），无卡顿感。
另外这个算法没有状态依赖，**跳到哪里都能往回翻**。

### 5. 阅读列表：渲染路径绝对不能做 I/O 重活

第一版在表格的 `viewFor` 和缺失统计里直接调 `BookPathResolver.resolve`。
那个函数对「找不到」的路径会**递归遍历** ~/Documents、~/Downloads、~/Desktop。
一次重绘有十几个单元格 → 十几个目录遍历压在主线程上 → 界面假死。

表现极具迷惑性：**书架窗口关不掉、按钮点不动**，看起来像 AppKit 的问题，
实际是主线程被自己的文件搜索堵住了。

现在分成两层：

| 用途 | 接口 | 成本 |
|---|---|---|
| 渲染 / 计数 | `refreshAvailability()` + `availableURL(forStoredPath:)` | 只做 `fileExists`，主线程安全 |
| 真正找搬走的文件 | `searchMissingFiles()` | 昂贵，**后台队列**，完成后回调刷新 |
| 算全书字数（显示百分比） | `prefetchLengths()` | 昂贵，**后台队列**，分批 + 总量上限 |

「进度」列为什么显示百分比而不是字符偏移：偏移是实现细节，用户看不懂
「7000 字」意味着读到哪了。总字数由后台算出后缓存；**百分比钳制在 0~100** ——
存档里的偏移可能大于当前文件长度（文件被编辑过 / 从别处导入），
不钳制就会出现 `7470.4%` 这种明显不对的显示。

### 6. 「进度」只有一个口径

曾经阅读界面按原版的 `(m_Index + m_PageLength) / m_Length`（**页末**）算，
阅读列表按存档里的 `item.index`（**页首**）算 —— 于是末页出现「阅读界面 100%、列表 99.7%」。

现在收敛成 `ReadingStatus.percent(offset:totalLength:)` 一个函数：

- 状态栏、触控栏、阅读列表**全部**调它；
- 函数签名强制传入 `offset` + `totalLength`，**不接受一个算好的百分比**——
  这样从类型上就不可能再各算各的；
- 口径统一为**当前页起始偏移占全书的比例**。理由是存档里只有页首偏移
  （这是与 Windows 版互通的前提，不能改），阅读列表能算出的只有它。

副作用：在末页进度不是 100%（因为按页首算）。所以状态栏会在末页追加「· 末页」标记，
免得读者以为还没读完。

### 7. 性能：度量缓存

原版每字符调一次 `GetTextExtentPoint32` 且**无任何缓存**，
一页 500~2000 次，每次重绘全量重测。
本项目用 `TextMetrics` 做逐码元 advance 缓存，这是相对原版最大的提升点。

---

## 数据存放位置

**设置、阅读列表、进度、书签全部存在同一个文件里**，路径是运行时算出来的
（`FileManager` 的 `applicationSupportDirectory`），**没有任何硬编码**：

```
~/Library/Application Support/Reader/.cache.dat
```

换用户、换机器会自动跟着变。这样设计是为了和 Windows 版共用同一份存档格式
（Windows 版把它放在 exe 同目录）。

### 正常使用只会产生这一个文件

实测（清空所有相关文件后跑一遍）确认：

| 路径 | 何时出现 |
|---|---|
| `…/Application Support/Reader/.cache.dat` | **总是**（首次保存时自动建目录） |
| `…/Preferences/com.lizhuohong.reader.plist` | 仅当你**移动/缩放**设置·书架·书签窗口，或打开设置窗口（系统给 `NSColorPanel` 记布局）。纯看书不会产生 |
| `.cache.dat.tmp-<pid>` | 每次保存的原子写临时文件，写完立刻替换，正常不残留 |
| `.cache.dat.corrupt-<时间戳>` | 存档损坏时的自动备份（防丢数据），一次性 |

明确不会产生：`Caches/`、`Saved Application State/`、`Containers/`、`Logs/`、
`HTTPStorages/`。软件完全离线，没有自动更新、没有网络请求。

只有主动操作才会写别处：**导出存档**（你选的位置）、**编辑模式保存**（写回那本 txt 原文，按原编码）。

### 便携模式（放 U 盘 / 同步盘）

**规则只有一条：`Reader.app` 旁边有没有一个叫 `portable` 的文件。**

| App 同目录 | 存档位置 |
|---|---|
| 没有 `portable` | 标准位置 `~/Library/Application Support/Reader/` |
| 有 `portable`（空文件即可） | App 同目录下的 `.cache.dat` |

开启：

```bash
mkdir -p /Volumes/U盘/Reader
cp -R Reader.app /Volumes/U盘/Reader/
touch /Volumes/U盘/Reader/portable       # ← 就这一步
```

关掉：删掉那个 `portable` 文件即可。

```
/Volumes/U盘/Reader/
├── Reader.app
├── portable          ← 有 = 便携；删掉 = 回标准位置
└── .cache.dat        ← 便携模式下自动生成
```

> **切换位置后是全新的数据。** 想带着书架和进度搬过去，手动把旧位置的
> `.cache.dat` 拷到新位置即可（标准位置在 `~/Library/Application Support/Reader/`）。
>
> 只读位置（比如直接在 DMG 里运行）会自动退回标准位置，不会「保存静默失败」。

设置界面「其他」页会显示当前用的是哪种模式。

### 完全自定义路径

```bash
READER_CACHE_PATH=/任意/位置/cache.dat ./run.sh
```

开发工具（`--*-selftest`、`--render-*`）会自动把存档重定向到临时目录，
不会污染真实数据 —— 这一条是踩过坑之后加的（见下方「踩过的坑」）。

---

## 踩过的坑

| 现象 | 根因 |
|---|---|
| 双击 txt / 拖到 Dock 图标时崩溃（`EXC_BREAKPOINT`） | `application(_:openFile:)` 在 `finishLaunching` 阶段就触发，**比 `applicationDidFinishLaunching` 更早** —— 那时窗口还没建，`open(url:)` 撞上隐式解包 nil。用 `isWindowReady` 挂起成 `pendingFile` 解决 |
| 点关闭按钮后「Reader 意外退出」 | `NSWindow.isReleasedWhenClosed` 默认 **true**。ARC 下 AppKit 关闭窗口时会额外发一次 `release`，把 ARC 那一个引用计数也减掉 → 窗口被释放，`window` 属性变野指针。随后 AppKit 自动 `terminate:`，`applicationWillTerminate` 里读 `window.frame` 直接 SIGSEGV。三个辅助窗口都设了 `false`，唯独主窗口漏了 |
| 任何 >4096 字节的 UTF-8 文件被误判编码 | `isValidUTF8` 的探测窗口正好把多字节字符切成两半时判成非法。原版 `Utils.cpp` 里作者留了注释 `break;//return 0; fixed bug.... substr`，移植时照搬了**修复前**的写法 |
| 往下滚正常、往上滚「飞快」，一下就回到开头 | `goPrevLines` 取的是 `collected[count - n]`，而 `collected` 是从近到远排的，正确下标是 `collected[n - 1]`。取错后上滚一格退回一整页（约 23 行），下滚一格只走 1 行。原测试里 `collected` 只有 3 个元素、`n=2`，`count-n` 恰好等于 `n-1` —— **碰巧蒙对了**。已改成跑真实页宽的对称性测试（下滚 N 步再上滚 N 步，位置序列必须完全镜像） |
| 上滚没用 | 拿 `previousPageStart`（页链）去推行链的「倒数第 N 行」，两条链不是一回事，会算出比当前位置还靠后的点 |
| 反色后「上滚」卡死回不到书首 | 二分方向取反了：应取**最小**的 `s` 使 `pageEnd(s) >= start`，取最大会跳过内容并提前卡死 |
| 调低窗口不透明度后，文字周围有一层虚影（像「看强光后视网膜上的残留」） | `isOpaque = false` 的窗口，macOS 是**按窗口的 alpha 蒙版去算阴影**的。背景调透明之后只剩文字不透明，阴影就变成了「文字轮廓」，看起来就是每个字后面拖着一层虚影。修复：透明时 `hasShadow = false`，并 `invalidateShadow()` 强制重算 |
| 自检工具把用户真实存档覆盖了 | `--library-selftest` 会 new 一个 `AppDelegate`，它的 `library` 是 `LibraryStore.shared` → 真实路径。改成：命令行里出现任何开发工具开关时，`main.swift` 顶部先 `setenv("READER_CACHE_PATH", 临时目录)`，`LibraryStore.shared` 初始化时读取该变量 |
| 设置界面显示的存档路径不对 | 「其他」页用的是 `LibraryStore.shared.fileURL`（全局单例）而不是构造时传入的 `store.fileURL`。正式运行时两者相同，但离屏渲染工具塞的是临时 store，于是显示成了真实路径 |
| 自动翻页开着时间隔 / 方式改了不生效 | 定时器是 `Timer(timeInterval:repeats: true)`，间隔和模式在建的时候就捕获进去了。改成**每次触发后按当前设置重新排一次**（非重复定时器），并在设置变化时先 `invalidate()` 旧定时器再排新的 —— 只建新的不管旧的会让两个定时器同时跑 |
| 「点击翻页」和「原版 page_mode 预设」想表达的是两件事 | 原版是三种预设（不翻页 / 左右翻页 / 三分区），但用户真正想要的是**每个键单独指定动作**。改成三个下拉框后语义更清楚，同时仍按原字段 `page_mode` / `disable_lrhide` 反向推导写盘，Windows 版读到不会错乱 |
| 设置窗口用 `NSTabView` 标签文字是空的、内容沉到底部 | 两个坑：① `NSTabView` 在离屏渲染下标签文字画不出来；② `NSScrollView` 的文档视图原点在左下角，内容比可视区矮时就会沉到底部。改用 `NSSegmentedControl` 自己管切换 + 一个 flipped 文档视图 |
| 设置里改不了字体颜色和背景颜色 | 色块写的是 `isEnabled = !followSystemAppearance`，而「跟随系统深色模式」**默认开启** → 两个色块一直是禁用状态，看起来就像功能坏了。改成色块永远可点；跟随系统时显示实际生效的系统配色，用户一选色就自动退出跟随 |
| 编辑模式保存 UTF-16 文件后读不回来 | 写回时忘了加 BOM。解码端就是靠 BOM 认 UTF-16 的，不补 BOM 会被当成 UTF-8 读出乱码 |
| 平滑滚动方向反了（内容往下推、顶部留白） | AppKit 的 y 轴向上，内容要「往上滚出屏幕」必须让 y **变大**，写成 `top - scrollOffset` 正好相反 |
| qlmanage 渲染的 SVG 量不出图案 | `qlmanage -t` 输出的是**不透明白底**。改用 `NSImage` 直接矢量光栅化（保留透明度） |
| 设置界面底部被截断 | 窗口高度写死；改为按 `grid.fittingSize` 自适应 |
| 拖字距 / 行距 / 段距滑块时正文变了，设置里的数字不变 | `addSliderRow` 创建的数值标签是**局部变量**：`spacingChanged` 只把值写进设置并重排阅读界面，没有任何人再去更新那几个 `NSTextField`。修复：用 `sliderValueLabels` 登记滑块和标签，拖动时统一刷新；`syncFromSettings` 里也刷一次（否则重开设置窗口显示的还是初始值） |
| 设置窗口里每一项改起来都很卡，长篇小说尤其明显 | 设置里的滑块是 `isContinuous`，每拖一下都会走 `applySettingsToReader()`，而它**无条件**执行 `book.chapterRule = s.chapterRule` —— `chapterRule` 的 `didSet` 会把全书章节重新解析一遍。6.4M 个 UTF-16 码元实测约 **1.3 秒/次**，所以拖字号、行距全在等解析。修复：`ChapterRule` 改为 `Equatable`，`TextBook.applyChapterRule()` 只在规则真的变化时才重解析；打开书时也跳过与默认值相同的重复解析 |

---

## 应用图标

源文件放在 `Resources/`：

| 文件 | 用途 |
|---|---|
| `阅读.svg` | **主源**（真矢量，`viewBox 0 0 1024 1024`） |
| `阅读.png` | 备用（256×256 透明底） |

`build.sh` 调 `tools/MakeIcon.swift` 自动生成 `Resources/AppIcon.icns`（10 个尺寸，
覆盖 Retina），源图更新时才会重新生成。

工具做四件事：

1. **矢量渲染** —— SVG 走 `NSImage` 按目标尺寸光栅化。
   > ⚠️ **不要用 `qlmanage`**：它渲染 SVG 会带一层**不透明白底**，
   > 导致「量包围盒重新居中」完全失效。
2. **重新居中** —— 量出不透明部分的包围盒，再摆到画布正中
   （原始素材一般不居中，直接用会明显偏）。
3. **圆角矩形（squircle）** —— macOS 的 App 图标既不是方的也不是普通圆角，
   而是「1024 画布里 824×824 主体 + 185.4 圆角」。不套这个形状，
   在 Dock 里会比别的图标大一圈、形状也不对。
4. **浅渐变** —— 纯平底色在深色壁纸下很死板。

底色和图案占比可以覆盖：

```bash
ICON_BG='#E4F5F0' ICON_SCALE=0.66 ./build.sh     # 换个底色 / 放大图案
```

> macOS 有图标缓存。改完没立刻生效的话：`touch dist/Reader.app && killall Dock`

---

## 触控栏（Touch Bar）

面向带 Touch Bar 的 MacBook Pro（已确认机型 **Mac14,7 = 13" M2 2022**）。
不带触控栏的机器上这些 API 是**安全的空操作**，不会有任何副作用。

**常驻区**（横向空间有限，只放最高频的）：

```
[文件]  ◀ 上一页   书名 · 章节标题 · 12.3%   下一页 ▶  [阅读]
```

进度标签的格式是 `书名 · 章节标题 · 百分比`，用**中间截断** ——
尾部截断会把百分比切掉，那是读者最需要的信息之一。
实测（13pt 系统字体）：一般小说约 210~270pt，长书名 + 长章节标题约 356pt，
而标签可用宽度约 450pt，所以正常情况下不会截断。

**「文件」popover**：打开… / 阅读列表 / 导出存档… / 显示存档
**「阅读」popover**：◀◀ 上一章 / 下一章 ▶▶ / 加书签 / A− / A＋

**可选条目**（默认不显示，在 **视图 → 自定义触控栏…** 里拖出来）：
上一章、下一章、加书签、A−、A＋

设计取舍：触控栏大约只放得下 5~6 个元素，所以长尾操作全部收进两侧的 popover，
点开才展开；而不是平铺一长排导致被系统挤掉。

对应的菜单项也补齐了：**阅读 → 添加书签** `⌘M`、**放大/缩小字号** `⌘=` / `⌘-`
（与原版的 `Ctrl+M` / `Ctrl+=` / `Ctrl+-` 对应）。

排查工具（触控栏没法截图，靠它核对结构）：

```bash
./dist/Reader.app/Contents/MacOS/Reader --dump-touchbar
```

---

## `.cache.dat`：和 Windows 版共用同一份存档

这是本项目相对原版最大的增量能力。原版把**全部状态**（设置 + 书架 + 进度 + 书签 + 书源）
存在 exe 同目录的一个文件里，格式是「JSON 文本整体 XOR 0x3a」。

macOS 版完全按同一格式读写，位置在：

```
~/Library/Application Support/Reader/.cache.dat
```

> ⚠️ **找不到是正常的**，有两层隐藏叠加：
> 1. `.cache.dat` 以点开头 → 隐藏文件；
> 2. `~/Library` 本身在 Finder 里就是隐藏的（macOS 10.7 起的设计）。
>
> 三种打开方式：
> - 菜单 **文件 → 在访达中显示存档**（`⇧⌘S`）
> - Finder 里按 `⌘⇧.` 显示隐藏文件，再按 `⌘⇧G` 粘贴上面的路径
> - 终端 `open -R ~/Library/Application\ Support/Reader/.cache.dat`
>
> 菜单里还有 **复制存档路径** 和 **导出存档…**（导出后放回 Windows 版 Reader 的 exe 同目录即可）。

于是：

| 场景 | 结果 |
|---|---|
| 从 Windows 迁到 Mac | 把 `.cache.dat` 放到 `~/Library/Application Support/Reader/` 即可，书架 / 进度 / 书签 / 设置全部保留 |
| 从 Mac 带回 Windows | 直接把 `.cache.dat` 放回 Windows 版 exe 同目录即可 |
| 备份 / 换机 | `文件 → 导出存档…` |

> 应用里**没有**「导入存档」入口 —— 正常使用只有一台电脑，不需要来回倒。
> 但文件格式始终兼容，手工把存档放过去就能用；Windows 路径的书会在书架上标成
> 「⚠️ 找不到文件」，选中后点「重新定位…」指认新位置，
> **进度和书签会原样保留**（它们记的是字符偏移，与路径无关）。

**为什么进度能跨平台**：`item.index` 存的是「经 `FormatText` 处理后文本的 UTF-16 字符偏移」，
不是页码、不是字节偏移、也不是文件路径相关的东西。所以只要 `FormatText` 复刻正确，
**即使文件路径变了（`D:\小说\a.txt` → `/Users/你/books/a.txt`），进度依然精确对应**。

几个实现细节：

- **保序无损**：持久化层用「保序 JSON + 类型化访问器」，而不是直接 `Codable`。
  规范表之外的字段（比如将来 Windows 版新增的键）会原样保留 —— 否则 macOS 版一存盘
  就会把按键绑定、书源等尚未实现功能的配置抹掉。
- **写出的键顺序**与 cJSON 一致（`json_header_t` 的插入顺序），方便比对排查。
- **原子写入**（临时文件 + `replaceItemAt`），掉电不会写坏存档。
- **颜色是 BGR**：Win32 的 `COLORREF` 是 `0x00BBGGRR`，与 RGB 顺序相反，转换时已处理。
- **字体换算**：`LOGFONT.lfHeight` 是 96 DPI 下的像素高（负数），点值 = 像素 × 72 / 96。
- **窗口位置的坐标系**：Win32 的屏幕原点是**主屏左上角、y 轴向下**，Cocoa 是**左下角、y 轴向上**，
  两边换算要翻转 y。判定「旧位置还能不能用」的标准不是「窗口有一部分可见」，
  而是**标题栏必须基本可见** —— 否则用户根本没法把窗口拖回来。

---

## 与原版的关系

- 项目基于 [binbyu/Reader](https://github.com/binbyu/Reader)（作者 Binbin Yu）。
- 原项目**没有 LICENSE 文件**，README 声明「版权归作者所有、严禁商业用途」。
  本项目沿用同样精神，不作商业分发；建议后续以 PR / 分支形式回馈上游。
- `reference/Reader/` 下原版源码的可移植逻辑（`FormatText`、章节规则、`.cache.dat` 格式）
  在本项目中被重新实现，不是直接复制。

---

## 发版（Release）

发行包**手动**发布。曾试过用 GitHub Actions 在 tag 上自动构建 + 发 Release，但 CI 的
macOS 镜像与本地环境不一致，两次都挂在构建阶段，于是撤回（见 `2ffe6bf`）。
以后要重做自动化，先在本地复现 CI 环境再上。

### 1. 改版本号

`Resources/Info.plist`：

```xml
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
```

下面所有命令里的版本号都**从 plist 读**，不要手抄。

### 2. 构建 + 全量验证

```bash
./verify.sh
# 构建 → 381 项单测 → 启动冒烟 → 窗口自检 → 离屏渲染，任何一步失败都会停
```

### 3. 打包（必须用 ditto，不能用 zip）

GitHub Release 只接受**文件**，而 `Reader.app` 是目录，所以必须压缩；
而且**不能用 `zip -r`**——它会丢扩展属性，app 签名随之失效，别人解压后打不开：

```bash
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ZIP="dist/Reader-${VERSION}-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Reader.app "$ZIP"
shasum -a 256 "$ZIP" > dist/SHA256SUMS.txt
```

打完之后**验证签名还在**（zip 方式弄错时这一步能立刻发现）：

```bash
rm -rf /tmp/relcheck && mkdir /tmp/relcheck
ditto -x -k "$ZIP" /tmp/relcheck
codesign --verify --deep --strict /tmp/relcheck/Reader.app && echo "签名 OK"
```

### 4. 打 tag 并推送

tag 名就是 `v<版本>`：

```bash
git tag -a "v${VERSION}" -m "Reader ${VERSION}"
git push origin "v${VERSION}"
```

### 5. 在网页上传

打开 https://github.com/LeeeZH/Reader-macOS/releases/new （tag 已存在会自动选上）：

- 标题：`Reader ${VERSION}`
- 描述：粘下面的模板
- 附件：`dist/Reader-${VERSION}-macos-arm64.zip` + `dist/SHA256SUMS.txt`
- 不要勾 pre-release

### 6. 上传后必须验证

```bash
# README 里用的就是这条永久链接，换版本也不用改
curl -sL -o /tmp/dl.zip -w '%{http_code}\n' \
  "https://github.com/LeeeZH/Reader-macOS/releases/latest/download/Reader-${VERSION}-macos-arm64.zip"
shasum -a 256 /tmp/dl.zip     # 必须与 dist/SHA256SUMS.txt 一致
```

### 注意事项

| 事项 | 说明 |
|---|---|
| 资产命名 | 保持 `Reader-<版本>-macos-arm64.zip`，README 的 `releases/latest/download/...` 才不用改 |
| 未公证 | `build.sh` 只做 ad-hoc 签名。别人首次打开必须「右键 → 打开」，或 `xattr -dr com.apple.quarantine /Applications/Reader.app` |
| 仅 arm64 | Intel Mac 跑不了，README 与 Release 说明都要写明 |
| 体积 | Release 单文件上限 2 GiB；当前安装包 562 KB，完全不是问题 |

### Release 说明模板

````markdown
macOS 原生 TXT 阅读器，重写自 binbyu/Reader，阅读存档与 Windows 版互通。

## 下载安装
1. 解压 zip，把 `Reader.app` 拖进「应用程序」
2. **首次打开请右键 → 打开**（本版未做 Apple 公证）
   或执行：`xattr -dr com.apple.quarantine /Applications/Reader.app`

## 本次更新
- （列出改动）

## 校验
SHA256 见本页 `SHA256SUMS.txt`
````

---

## 下一步

按方案文档的路线图：

1. **全文搜索**（对应原版 Ctrl+F）——难点是「搜索结果 ↔ 分页字符偏移」的映射，跳转复用 `jump(to:)`
2. **章节标题独立字体 / 颜色**——`use_same_font` / `font_title` / `title_color` 字段已经能读写，渲染层还没做双字体
3. **背景图片**（拉伸 / 平铺）、**无边框窗口**
4. **在线书源**（P2）——对照 `reference/Reader/Reader.cpp` 里 `ENABLE_NETWORK` 那段
5. **EPUB**（P3）——对照 `EpubBook.cpp` / `Epub.cpp`；MOBI 建议放弃
6. 持续补 **parity 测试**：用原版导出同一批 TXT 的「章节列表 + 每页首字符偏移」，逐页比对
