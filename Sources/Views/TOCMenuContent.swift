import Foundation

/// 「目录」菜单的内容模型。
///
/// 单独拆出来，是为了让单测能直接断言结构和数量：
/// 早期版本在菜单里截断到前 300 章，长篇小说（几千章）后面的章节
/// 在目录里根本点不到。这里**不做任何数量上限**，全部章节原样给出。
///
/// 菜单打开时如果总是从第 1 章开始列，读了两千章的人还得滚半天才能
/// 看见自己读到哪。所以内容分成两段：
///   · `earlier`：当前章之前的章节 —— 放进菜单顶部的子菜单，不占平铺位置；
///   · `active`：当前章 + 后面的章节 —— 平铺，当前章排在第一个并打勾。
/// 这样一点开「目录」，看到的第一章就是当前正在读的这章。
enum TOCMenuContent {

    struct Entry: Equatable {
        /// 菜单项标题，带全书序号：`12. 第十二章 标题`
        let title: String
        /// 章节下标（`chapters` 数组里的位置），`jumpToChapter` 用这个
        let chapterIndex: Int
        /// 是不是当前正在读的章节（菜单里打勾）
        let isCurrent: Bool
    }

    /// 菜单的两段内容
    struct Sections: Equatable {
        /// 当前章之前的章节，**离当前最近的在前**（菜单里就是「往回翻」）
        let earlier: [Entry]
        /// 当前章及之后的章节，当前章在最前面
        let active: [Entry]
    }

    /// 把整本书的章节映射成目录菜单项。
    ///
    /// - Parameters:
    ///   - chapters: 全书章节，保持文件里的顺序
    ///   - currentIndex: 当前章节下标；没有书、没识别到章节、或越界时传 `nil`
    static func entries(chapters: [Chapter], currentIndex: Int?) -> [Entry] {
        let current = currentIndex.flatMap { chapters.indices.contains($0) ? $0 : nil }
        return chapters.enumerated().map { i, chapter in
            Entry(title: "\(i + 1). \(chapter.title)",
                  chapterIndex: i,
                  isCurrent: i == current)
        }
    }

    /// 按「当前章」把目录切成两段。
    ///
    /// 前面的章节倒序给出（当前章的前一章在最上面），和「当前章 + 后续章节」
    /// 一起构成「从当前阅读位置向两边展开」的菜单 —— 点开目录第一眼就是现在读到的位置。
    ///
    /// 当前章下标非法（没书 / 越界）时不做切分，全部平铺 —— 和原来的行为一致。
    static func sections(chapters: [Chapter], currentIndex: Int?) -> Sections {
        let all = entries(chapters: chapters, currentIndex: currentIndex)
        guard let current = currentIndex.flatMap({ chapters.indices.contains($0) ? $0 : nil }),
              current > 0 else {
            return Sections(earlier: [], active: all)
        }
        return Sections(earlier: Array(all[..<current].reversed()),
                        active: Array(all[current...]))
    }
}
