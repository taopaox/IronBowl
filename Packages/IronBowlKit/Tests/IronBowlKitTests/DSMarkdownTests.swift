import Foundation
import Testing
@testable import IronBowlKit

@Test func parsesHeadingsListsCheckboxesQuotesTablesAndCode() {
    let md = """
    # 一级标题
    ### 三级标题

    - [x] 已完成任务
    - [ ] 待处理任务
      1. 缩进有序项

    > 引用第一行
    > 引用第二行

    | 项目 | 工时 |
    | --- | --- |
    | 饭碗 | 4h |
    | 日历 | 2h |

    ```swift
    print("hello")
    ```

    ---

    「**中文加粗**」与 *斜体* 和 `行内代码` 以及 [链接](https://example.com)
    """

    let blocks = DSMarkdown.parseBlocks(md)
    #expect(blocks.contains(.heading(id: 0, level: 1, text: "一级标题")))
    #expect(blocks.contains(.heading(id: 1, level: 3, text: "三级标题")))
    #expect(blocks.contains(.bullet(id: 2, indentLevel: 0, marker: "•", text: "已完成任务", checked: true)))
    #expect(blocks.contains(.bullet(id: 3, indentLevel: 0, marker: "•", text: "待处理任务", checked: false)))
    #expect(blocks.contains(.bullet(id: 4, indentLevel: 1, marker: "1.", text: "缩进有序项", checked: nil)))
    #expect(blocks.contains(.blockquote(id: 5, text: "引用第一行\n引用第二行")))
    #expect(blocks.contains(.table(id: 6, headers: ["项目", "工时"], rows: [["饭碗", "4h"], ["日历", "2h"]])))
    #expect(blocks.contains(.codeBlock(id: 7, language: "swift", code: "print(\"hello\")")))
    #expect(blocks.contains(.divider(id: 8)))

    let inline = DSMarkdown.attributedInline("「**中文加粗**」与 *斜体* 和 `行内代码` 以及 [链接](https://example.com)")
    let boldRun = inline.runs.first { String(inline[$0.range].characters) == "中文加粗" }
    #expect(boldRun?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    let italicRun = inline.runs.first { String(inline[$0.range].characters) == "斜体" }
    #expect(italicRun?.inlinePresentationIntent?.contains(.emphasized) == true)
    let codeRun = inline.runs.first { String(inline[$0.range].characters) == "行内代码" }
    #expect(codeRun?.inlinePresentationIntent?.contains(.code) == true)
    let linkRun = inline.runs.first { String(inline[$0.range].characters) == "链接" }
    #expect(linkRun?.link == URL(string: "https://example.com"))
}
