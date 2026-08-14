import Foundation

@main
enum TerminalANSIValidation {
    static func main() {
        let escape = "\u{1B}"
        let backspace = "\u{8}"
        check("plain", "hello", ["hello"])
        check("blank-middle", "a\n\nb", ["a", "", "b"])
        check("trailing-terminator", "a\n", ["a"])
        check("cr-redraw", "100%\rOK", ["OK0%"])
        check("backspace-overwrite", "abc\(backspace)\(backspace)XY", ["aXY"])
        check("erase-rest", "100%\r\(escape)[KOK", ["OK"])
        check("erase-all-keeps-cursor", "abcd\(escape)[2Kx", ["    x"])
        check("tab-stop", "a\tb\rXY", ["XY      b"])
        check("wide-redraw", "中x\rab", ["abx"])
        check("osc", "a\(escape)]0;title\u{7}b", ["ab"])
        check("non-csi", "x\(escape)(By\(escape)cz", ["xyz"])
        check("sgr-carries", "\(escape)[31mfirst\nsecond", ["first", "second"])
        check("only-control-empty", "\(escape)[0m\(escape)[2K", [""], empty: true)

        let styled = TerminalANSIParser.parse("\(escape)[1;3;31mred\(escape)[0m")
        precondition(styled.lines.first?.spans.count == 1, "styled: expected one span")
        precondition(styled.lines.first?.spans.first?.text == "red", "styled: text mismatch")
        precondition(styled.lines.first?.spans.first?.style.bold == true, "styled: bold missing")
        precondition(styled.lines.first?.spans.first?.style.italic == true, "styled: italic missing")

        let trueColor = TerminalANSIParser.parse("\(escape)[38;2;10;20;30mx")
        precondition(trueColor.lines.first?.spans.first?.text == "x", "truecolor: text mismatch")
        print("TerminalANSIValidation: 15 fixtures passed")
    }

    private static func check(_ name: String, _ input: String, _ expected: [String], empty: Bool = false) {
        let parsed = TerminalANSIParser.parse(input)
        let actual = parsed.lines.map(\.plainText)
        precondition(actual == expected, "\(name): expected \(expected), got \(actual)")
        precondition(parsed.isEmpty == empty, "\(name): empty mismatch")
    }
}
