# AGENTS.md

给在本仓库里干活的 AI agent / 新贡献者的约定。**第一条最重要。**

## 1. 测试节奏：日常只跑「被改到的那一小块」，全量测试只在打包时跑

`./verify.sh` 是**打包 / 发版前**的一次性全量验证（构建 + 单测 + 启动冒烟 +
20 多个自检进程 + 十几张离屏渲染，单次 3–4 分钟）。**不要在迭代过程中反复跑它**——
既慢，又会在用户屏幕上闪窗 / 抢焦点（虽然现在有安静模式，见 §2）。

日常迭代按改动范围选最小验证：

| 改动 | 跑什么 |
|---|---|
| 核心逻辑（解码 / 章节 / 设置结构 / 搜索 / 存档） | `./test.sh` |
| 某个窗口 / 交互 | 对应自检，例如 `$B --shortcut-selftest`、`$B --find-selftest`、`$B --toc-selftest` |
| 排版 / 渲染 | 离屏渲染一张图 + `$B --dump-pages` 和 `samples/golden-pages.tsv` 比 |
| 窗口 / 面板位置、AppKit 行为 | 对应 `--xxx-selftest`，不要靠肉眼开 app 点点点 |

其中 `$B = ./dist/Reader.app/Contents/MacOS/Reader`（先 `./build.sh`）。

**只有准备打包 / 发版时**才完整跑一次 `./verify.sh`。跑之前先告诉用户「要跑全量
（约 3–4 分钟）」，不要在用户正用电脑时静默开跑。

## 2. 开发工具默认「安静模式」，不要关掉

所有 `--xxx-selftest` / `--render-*` 进程默认 `READER_DEVTOOLS_QUIET=1`：

- App 激活策略是 `.accessory`（不进 Dock、不抢菜单栏）；
- 不调用 `NSApp.activate(ignoringOtherApps:)`；
- 窗口 `alphaValue = 0` 并尽量挪到屏幕外，用户看不到闪窗。

实现见 `Sources/Views/DevTools.swift`。**不要为了让自检窗口可见而关掉它**；
手工排查确实需要看窗口时，临时用：

```bash
READER_DEVTOOLS_QUIET=0 $B --shortcut-selftest
```

正常启动（双击 / `./run.sh` / 打包后的用户）不受影响。

## 3. 构建与运行

```bash
./build.sh          # 编译 → dist/Reader.app（零第三方依赖，纯 swiftc）
./run.sh            # 编译并启动
./run.sh --console  # 前台运行，看日志
./test.sh           # 核心逻辑单测（649 项，秒级）
./verify.sh         # 全量验证 —— 仅打包/发版前
```

## 4. 数据安全：测试绝不碰真实存档

开发工具会自动把 `READER_CACHE_PATH` 重定向到临时目录；新增自检 / 渲染工具时
也必须沿用这条路径，**绝不能读写** `~/Library/Application Support/Reader/.cache.dat`
（用户的书架、进度、书签都在里面）。

## 5. 代码约定（关键几条）

- **零第三方依赖**，不引入 SwiftPM / Xcode 工程；只改 `Sources/` 里的 Swift 文件。
- `ShortcutAction.rawValue`、`.cache.dat` 的 header 字段名是**已发布的数据格式**，
  不能改名（会丢用户自定义键位 / 阅读进度）。
- 菜单键位、状态栏 / 各窗口提示里的快捷键文案必须从设置实时取，**不要写死** `⌘X`。
- 改 UI 时优先复用现有的 `NSGridView` / 自定义视图风格；设置页里的控件要能真的生效，
  不做「点了没反应」的开关。

## 6. 文档

`docs/DEVELOPMENT.md` 是工程细节、自检说明和踩坑记录的权威来源；
改行为、加自检、修 bug 时同步更新它。`README.md` 面向用户，只在用户可见行为变化时改。
