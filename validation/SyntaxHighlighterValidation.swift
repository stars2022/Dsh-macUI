import Foundation

@main
enum SyntaxHighlighterValidation {
    static func main() {
        let typescript = NativeSyntaxHighlighter.lines("const answer: number = 42\n// note", language: "ts")
        precondition(typescript?.count == 2)
        precondition(typescript?[0].map(\.text).joined() == "const answer: number = 42")
        precondition(typescript?[0].first(where: { $0.text == "const" })?.kind == .keyword)
        precondition(typescript?[0].first(where: { $0.text == "42" })?.kind == .constant)
        precondition(typescript?[1] == [SyntaxRun(text: "// note", kind: .comment)])

        let multiline = NativeSyntaxHighlighter.lines("/* first\nsecond */ const x = 1", language: "js")
        precondition(multiline?.count == 2)
        precondition(multiline?[0].first?.kind == .comment)
        precondition(multiline?[1].first?.kind == .comment)
        precondition(multiline?[1].contains(where: { $0.text == "const" && $0.kind == .keyword }) == true)

        let python = NativeSyntaxHighlighter.lines("def f(value):\n    return \"ok\"", language: "py")
        precondition(python?[0].first(where: { $0.text == "def" })?.kind == .keyword)
        precondition(python?[0].first(where: { $0.text == "f" })?.kind == .function)
        precondition(python?[1].first(where: { $0.text == "\"ok\"" })?.kind == .string)
        let triple = NativeSyntaxHighlighter.lines("\"\"\"first\nsecond\"\"\"\nreturn 1", language: "py")
        precondition(triple?[0].first?.kind == .string && triple?[1].first?.kind == .string)
        precondition(triple?[2].first(where: { $0.text == "return" })?.kind == .keyword)

        let aliases = ["typescript", "tsx", "javascript", "jsx", "shellscript", "bash", "sh", "shell", "zsh", "json", "jsonc", "python", "rb", "ruby", "go", "rs", "rust", "java", "c", "cpp", "cs", "csharp", "kotlin", "swift", "php", "yaml", "yml", "toml", "ini", "md", "markdown", "mdx", "html", "css", "scss", "less", "sql", "xml", "lua"]
        for alias in aliases { precondition(NativeSyntaxHighlighter.lines("x", language: alias) != nil, "missing alias \(alias)") }
        precondition(NativeSyntaxHighlighter.lines("IDENTIFICATION DIVISION.", language: "cobol") == nil)
        precondition(NativeSyntaxHighlighter.lines("x", language: nil) == nil)

        let trailing = NativeSyntaxHighlighter.lines("const x = 1\n", language: "ts")
        precondition(trailing?.count == 1)
        let genuineBlank = NativeSyntaxHighlighter.lines("x\n\n", language: "ts")
        precondition(genuineBlank?.count == 2 && genuineBlank?[1].isEmpty == true)

        print("SyntaxHighlighterValidation: aliases and 9 fixtures passed")
    }
}
