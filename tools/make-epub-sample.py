#!/usr/bin/env python3
"""生成 samples/古文观止.epub —— EPUB 原型 / 自检用的样书夹具。

不是应用运行时依赖，也不参与构建：只在样书内容变了、或需要重新打夹具时手动跑：
    python3 tools/make-epub-sample.py [输出路径]

夹具要求（和真实 EPUB 保持一致，才能测到解包 / container / OPF / spine 整条路）：
- `mimetype` 是 zip 的第一个条目且不压缩（EPUB 规范要求）；
- `META-INF/container.xml` → `OEBPS/content.opf`；
- 一个 spine 条目 = 一章，开头的 `<h1>` 就是章节标题；
- 正文按空行分段，输出成 `<p>`。
"""

import html
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "samples" / "古文观止.txt"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "samples" / "古文观止.epub"
TITLE = "古文观止（示例）"
BOOK_ID = "reader-sample-guwen"

CHAPTER_RE = re.compile(r"^\s*第[0-9一二三四五六七八九十百千零〇两]+[章卷回节]")


def split_chapters(text: str):
    chapters = []
    current = None
    for line in text.splitlines():
        if CHAPTER_RE.match(line):
            current = {"title": line.strip(), "paragraphs": []}
            chapters.append(current)
        elif current is not None:
            line = line.strip()
            if line:
                current["paragraphs"].append(line)
    return chapters


def chapter_xhtml(chapter) -> str:
    paragraphs = "\n".join(
        "  <p>" + html.escape(p) + "</p>" for p in chapter["paragraphs"]
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><meta charset="utf-8"/><title>{html.escape(chapter["title"])}</title></head>
<body>
  <h1>{html.escape(chapter["title"])}</h1>
{paragraphs}
</body>
</html>
"""


def nav_xhtml(chapters) -> str:
    items = "\n".join(
        f'      <li><a href="ch{i + 1}.xhtml">{html.escape(c["title"])}</a></li>'
        for i, c in enumerate(chapters)
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="utf-8"/><title>目录</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol>
{items}
    </ol>
  </nav>
</body>
</html>
"""


def opf_xml(chapters) -> str:
    manifest = "\n".join(
        f'    <item id="ch{i + 1}" href="ch{i + 1}.xhtml" media-type="application/xhtml+xml"/>'
        for i in range(len(chapters))
    )
    spine = "\n".join(
        f'    <itemref idref="ch{i + 1}"/>' for i in range(len(chapters))
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">{BOOK_ID}</dc:identifier>
    <dc:title>{html.escape(TITLE)}</dc:title>
    <dc:language>zh-CN</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{manifest}
  </manifest>
  <spine>
{spine}
  </spine>
</package>
"""


CONTAINER_XML = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def main():
    chapters = split_chapters(SRC.read_text(encoding="utf-8"))
    if not chapters:
        raise SystemExit("没有从样书里解析出章节")

    entries = [
        ("META-INF/container.xml", CONTAINER_XML),
        ("OEBPS/content.opf", opf_xml(chapters)),
        ("OEBPS/nav.xhtml", nav_xhtml(chapters)),
    ]
    for i, chapter in enumerate(chapters):
        entries.append((f"OEBPS/ch{i + 1}.xhtml", chapter_xhtml(chapter)))

    with zipfile.ZipFile(OUT, "w") as archive:
        # mimetype 必须是第一个条目且不压缩
        info = zipfile.ZipInfo("mimetype")
        info.compress_type = zipfile.ZIP_STORED
        archive.writestr(info, "application/epub+zip")
        for name, data in entries:
            archive.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)

    print(f"已生成 {OUT}（{len(chapters)} 章，{OUT.stat().st_size} 字节）")


if __name__ == "__main__":
    main()
