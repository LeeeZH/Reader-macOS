macOS 原生 TXT 阅读器，重写自 [binbyu/Reader](https://github.com/binbyu/Reader)，
阅读存档（书架 / 进度 / 书签）与 Windows 版互通。

## 下载安装

1. 下载本页的 `Reader-<版本>-macos-arm64.zip`，解压得到 `Reader.app`
2. 拖进「应用程序」文件夹
3. **第一次打开请右键点 `Reader.app` → 选择「打开」** —— 本版没有做 Apple 公证，
   直接双击会被系统拦下。之后就能正常双击启动了。

如果提示「已损坏」或不想每次右键，执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/Reader.app
```

## 功能

- 自动识别 UTF-8 / UTF-16 / GBK 编码，自动分章，不用转码
- 字体、字号、字距、行距、段距、页边距、配色全部可调；深色模式跟随系统
- 书架、阅读进度、书签持久化，兼容 Windows 版 `.cache.dat` 存档
- 摸鱼功能：全局热键 `⌃⌥H` 隐藏、窗口半透明、左右键一起按隐藏、自动翻页
- Touch Bar、多窗口、编辑模式、取色器

## 已知限制

- 仅支持 Apple Silicon（arm64），Intel Mac 暂不支持
- 未签名未公证，首次打开需右键「打开」（见上）
- 暂不支持：全文搜索、EPUB / MOBI、在线书源

## 校验

安装包的 SHA256 见本页的 `SHA256SUMS.txt`：

```bash
shasum -a 256 -c SHA256SUMS.txt
```
