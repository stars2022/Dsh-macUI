import Foundation

@main
enum NativeMarkdownValidation {
    static func main() {
        let fixture = """
        # 标题

        第一段，含 `inline`。

        - [x] 已完成
          - 嵌套项

        > 引用正文

        ---

        ```swift
        let answer = 42
        print(answer)
        ```

        | 名称 | 状态 |
        | --- | :---: |
        | Markdown | 完成 |
        """
        let blocks = NativeMarkdownParser.parse(fixture)
        precondition(blocks.count == 7)
        precondition(blocks[0] == .heading(level: 1, text: "标题"))
        precondition(blocks[1] == .paragraph("第一段，含 `inline`。"))
        precondition(blocks[2] == .list(ordered: false, start: 1, items: [
            .init(depth: 0, text: "已完成", checked: true, ordered: false),
            .init(depth: 1, text: "嵌套项", checked: nil, ordered: false),
        ]))
        precondition(blocks[3] == .quote([.paragraph("引用正文")]))
        precondition(blocks[4] == .thematicBreak)
        precondition(blocks[5] == .code(language: "swift", source: "let answer = 42\nprint(answer)"))
        precondition(blocks[6] == .table(header: ["名称", "状态"], rows: [["Markdown", "完成"]]))

        let ordered = NativeMarkdownParser.parse("3. 三\n4. 四")
        precondition(ordered == [.list(ordered: true, start: 3, items: [
            .init(depth: 0, text: "三", checked: nil, ordered: true, number: 3),
            .init(depth: 0, text: "四", checked: nil, ordered: true, number: 4),
        ])])

        let unclosed = NativeMarkdownParser.parse("~~~txt\nbody")
        precondition(unclosed == [.code(language: "txt", source: "body")])

        let setext = NativeMarkdownParser.parse("Title\n===\n\nSubtitle\n---\n\n---")
        precondition(setext == [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Subtitle"),
            .thematicBreak,
        ])

        let mixed = NativeMarkdownParser.parse("- parent\n  1. child one\n  2. child two\n    continuation\n- sibling")
        precondition(mixed == [.list(ordered: false, start: 1, items: [
            .init(depth: 0, text: "parent", checked: nil, ordered: false),
            .init(depth: 1, text: "child one", checked: nil, ordered: true, number: 1),
            .init(depth: 1, text: "child two\ncontinuation", checked: nil, ordered: true, number: 2),
            .init(depth: 0, text: "sibling", checked: nil, ordered: false),
        ])])

        let reverseMixed = NativeMarkdownParser.parse("2. parent\n  - child\n3. sibling")
        precondition(reverseMixed == [.list(ordered: true, start: 2, items: [
            .init(depth: 0, text: "parent", checked: nil, ordered: true, number: 2),
            .init(depth: 1, text: "child", checked: nil, ordered: false),
            .init(depth: 0, text: "sibling", checked: nil, ordered: true, number: 3),
        ])])

        print("NativeMarkdownValidation: 10 block kinds and 6 fixtures passed")
    }
}
