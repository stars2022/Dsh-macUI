import AppKit
import SwiftUI

enum SyntaxTokenKind: Equatable {
    case plain, constant, string, comment, keyword, parameter, function, stringExpression, punctuation, link
}

struct SyntaxRun: Equatable {
    let text: String
    let kind: SyntaxTokenKind
}

enum NativeSyntaxHighlighter {
    private enum Family: Equatable { case cLike, shell, python, ruby, markup, data, markdown, sql, lua }
    private enum ScanState: Equatable { case normal, blockComment, singleString, doubleString, tripleSingle, tripleDouble }

    private static let aliases: [String: Family] = [
        "typescript": .cLike, "ts": .cLike, "tsx": .cLike, "javascript": .cLike, "js": .cLike, "jsx": .cLike,
        "shellscript": .shell, "bash": .shell, "sh": .shell, "shell": .shell, "zsh": .shell,
        "json": .data, "jsonc": .data, "py": .python, "python": .python,
        "rb": .ruby, "ruby": .ruby, "go": .cLike, "rs": .cLike, "rust": .cLike,
        "java": .cLike, "c": .cLike, "cpp": .cLike, "cs": .cLike, "csharp": .cLike,
        "kotlin": .cLike, "swift": .cLike, "php": .cLike, "yaml": .data, "yml": .data,
        "toml": .data, "ini": .data, "md": .markdown, "markdown": .markdown, "mdx": .markdown,
        "html": .markup, "css": .cLike, "scss": .cLike, "less": .cLike, "sql": .sql,
        "xml": .markup, "lua": .lua,
    ]

    static func lines(_ source: String, language: String?) -> [[SyntaxRun]]? {
        guard let language, let family = aliases[language.lowercased()] else { return nil }
        var state = ScanState.normal
        var output: [[SyntaxRun]] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            output.append(scan(String(raw), family: family, state: &state))
        }
        if source.hasSuffix("\n"), output.count > 1 { output.removeLast() }
        return output
    }

    static func attributed(_ source: String, language: String?, fontSize: CGFloat = 12) -> AttributedString {
        guard let highlighted = lines(source, language: language) else {
            var plain = AttributedString(source)
            plain.font = .system(size: fontSize, design: .monospaced)
            plain.foregroundColor = .primary
            return plain
        }
        var result = AttributedString()
        for (lineIndex, line) in highlighted.enumerated() {
            if lineIndex > 0 { result.append(AttributedString("\n")) }
            for run in line {
                var value = AttributedString(run.text)
                value.font = .system(size: fontSize, design: .monospaced)
                value.foregroundColor = palette(run.kind)
                result.append(value)
            }
        }
        return result
    }

    static func attributedLines(_ source: String, language: String?, fontSize: CGFloat = 12) -> [AttributedString]? {
        guard let highlighted = lines(source, language: language) else { return nil }
        return highlighted.map { line in
            var result = AttributedString()
            for run in line {
                var value = AttributedString(run.text)
                value.font = .system(size: fontSize, design: .monospaced)
                value.foregroundColor = palette(run.kind)
                result.append(value)
            }
            return result.characters.isEmpty ? AttributedString(" ") : result
        }
    }

    private static func scan(_ line: String, family: Family, state: inout ScanState) -> [SyntaxRun] {
        if family == .markup { return scanMarkup(line, state: &state) }
        if family == .markdown { return scanMarkdown(line) }
        var runs: [SyntaxRun] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            if state == .blockComment {
                let end = find("*/", in: characters, from: index)
                let upper = end.map { $0 + 2 } ?? characters.count
                append(String(characters[index..<upper]), .comment, to: &runs)
                index = upper
                if end != nil { state = .normal }
                continue
            }
            if state == .tripleSingle || state == .tripleDouble {
                let marker = state == .tripleSingle ? "'''" : "\"\"\""
                let end = find(marker, in: characters, from: index)
                let upper = end.map { $0 + 3 } ?? characters.count
                append(String(characters[index..<upper]), .string, to: &runs)
                index = upper
                if end != nil { state = .normal }
                continue
            }
            let character = characters[index]
            if (family == .cLike || family == .data), has("//", at: index, in: characters) {
                append(String(characters[index...]), .comment, to: &runs); break
            }
            if family == .cLike, has("/*", at: index, in: characters) {
                state = .blockComment; continue
            }
            if (family == .shell || family == .python || family == .ruby || family == .data), character == "#" {
                append(String(characters[index...]), .comment, to: &runs); break
            }
            if family == .sql, has("--", at: index, in: characters) {
                append(String(characters[index...]), .comment, to: &runs); break
            }
            if family == .lua, has("--", at: index, in: characters) {
                append(String(characters[index...]), .comment, to: &runs); break
            }
            if family == .python, has("'''", at: index, in: characters) || has("\"\"\"", at: index, in: characters) {
                let marker = has("'''", at: index, in: characters) ? "'''" : "\"\"\""
                if let end = find(marker, in: characters, from: index + 3) {
                    let upper = end + 3
                    append(String(characters[index..<upper]), .string, to: &runs)
                    index = upper
                } else {
                    append(String(characters[index...]), .string, to: &runs)
                    state = marker == "'''" ? .tripleSingle : .tripleDouble
                    index = characters.count
                }
                continue
            }
            if character == "\"" || character == "'" || (family == .cLike && character == "`") {
                let upper = stringEnd(in: characters, from: index, delimiter: character)
                append(String(characters[index..<upper]), character == "`" ? .stringExpression : .string, to: &runs)
                index = upper; continue
            }
            if character.isNumber {
                var upper = index + 1
                while upper < characters.count, characters[upper].isNumber || ".xabcdefABCDEF_".contains(characters[upper]) { upper += 1 }
                append(String(characters[index..<upper]), .constant, to: &runs); index = upper; continue
            }
            if isIdentifierStart(character) || (family == .shell && character == "$" && index + 1 < characters.count) {
                var upper = index + 1
                while upper < characters.count, isIdentifierPart(characters[upper]) { upper += 1 }
                let word = String(characters[index..<upper])
                let kind: SyntaxTokenKind
                if keywords(family).contains(word.lowercased()) { kind = .keyword }
                else if family == .shell && word.hasPrefix("$") { kind = .parameter }
                else if nextNonSpace(characters, after: upper) == "(" { kind = .function }
                else if family == .data && nextNonSpace(characters, after: upper) == ":" { kind = .parameter }
                else { kind = .plain }
                append(word, kind, to: &runs); index = upper; continue
            }
            append(String(character), character.isWhitespace ? .plain : .punctuation, to: &runs)
            index += 1
        }
        return runs
    }

    private static func scanMarkup(_ line: String, state: inout ScanState) -> [SyntaxRun] {
        if state == .blockComment {
            if let range = line.range(of: "-->") { state = .normal; return [SyntaxRun(text: String(line[...range.upperBound]), kind: .comment), SyntaxRun(text: String(line[range.upperBound...]), kind: .plain)] }
            return [SyntaxRun(text: line, kind: .comment)]
        }
        if let start = line.range(of: "<!--") {
            var runs: [SyntaxRun] = []
            append(String(line[..<start.lowerBound]), .plain, to: &runs)
            if let end = line.range(of: "-->", range: start.lowerBound..<line.endIndex) {
                append(String(line[start.lowerBound..<end.upperBound]), .comment, to: &runs)
                append(String(line[end.upperBound...]), .plain, to: &runs)
            } else { append(String(line[start.lowerBound...]), .comment, to: &runs); state = .blockComment }
            return runs
        }
        var runs: [SyntaxRun] = []
        let pattern = try? NSRegularExpression(pattern: "</?[A-Za-z][^>]*>")
        let ns = line as NSString
        var location = 0
        for match in pattern?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if match.range.location > location { append(ns.substring(with: NSRange(location: location, length: match.range.location - location)), .plain, to: &runs) }
            append(ns.substring(with: match.range), .keyword, to: &runs)
            location = match.range.location + match.range.length
        }
        if location < ns.length { append(ns.substring(from: location), .plain, to: &runs) }
        return runs
    }

    private static func scanMarkdown(_ line: String) -> [SyntaxRun] {
        if line.hasPrefix("#") { return [SyntaxRun(text: line, kind: .keyword)] }
        var runs: [SyntaxRun] = []
        let pattern = try? NSRegularExpression(pattern: "(`[^`]*`|\\[[^\\]]+\\]\\([^\\)]+\\)|\\*\\*[^*]+\\*\\*)")
        let ns = line as NSString
        var location = 0
        for match in pattern?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if match.range.location > location { append(ns.substring(with: NSRange(location: location, length: match.range.location - location)), .plain, to: &runs) }
            let value = ns.substring(with: match.range)
            append(value, value.hasPrefix("[") ? .link : value.hasPrefix("`") ? .string : .keyword, to: &runs)
            location = match.range.location + match.range.length
        }
        if location < ns.length { append(ns.substring(from: location), .plain, to: &runs) }
        return runs
    }

    private static func keywords(_ family: Family) -> Set<String> {
        switch family {
        case .cLike: return ["as","async","await","break","case","catch","class","const","continue","default","defer","do","else","enum","export","extends","false","final","for","func","function","guard","if","import","in","interface","let","match","mut","new","nil","null","package","private","protocol","public","return","static","struct","switch","throw","throws","true","try","type","var","void","while","yield"]
        case .shell: return ["case","do","done","elif","else","esac","fi","for","function","if","in","select","then","time","until","while"]
        case .python: return ["and","as","assert","async","await","break","class","continue","def","del","elif","else","except","false","finally","for","from","global","if","import","in","is","lambda","none","not","or","pass","raise","return","true","try","while","with","yield"]
        case .ruby: return ["begin","break","case","class","def","do","else","elsif","end","ensure","false","for","if","module","next","nil","redo","rescue","retry","return","self","super","then","true","unless","until","when","while","yield"]
        case .sql: return ["alter","and","as","asc","begin","by","case","create","delete","desc","distinct","drop","else","end","from","group","having","in","insert","into","is","join","limit","not","null","on","or","order","select","set","table","then","union","update","values","when","where"]
        case .lua: return ["and","break","do","else","elseif","end","false","for","function","goto","if","in","local","nil","not","or","repeat","return","then","true","until","while"]
        default: return []
        }
    }

    private static func palette(_ kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .plain: return .primary
        case .constant: return adaptive(light: 0x1c7ed6, dark: 0x4dabf7)
        case .string: return adaptive(light: 0x2f9e44, dark: 0x69db7c)
        case .comment: return adaptive(light: 0x868e96, dark: 0xadb5bd)
        case .keyword: return adaptive(light: 0xd6336c, dark: 0xfaa2c1)
        case .parameter: return adaptive(light: 0xe8590c, dark: 0xffa94d)
        case .function: return adaptive(light: 0x6741d9, dark: 0xb197fc)
        case .stringExpression: return adaptive(light: 0x2b8a3e, dark: 0x8ce99a)
        case .punctuation: return adaptive(light: 0x495057, dark: 0xced4da)
        case .link: return adaptive(light: 0x1971c2, dark: 0x74c0fc)
        }
    }

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) })
    }
    private static func rgb(_ value: Int) -> NSColor { NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1) }
    private static func append(_ text: String, _ kind: SyntaxTokenKind, to runs: inout [SyntaxRun]) { guard !text.isEmpty else { return }; if runs.last?.kind == kind { let last = runs.removeLast(); runs.append(SyntaxRun(text: last.text + text, kind: kind)) } else { runs.append(SyntaxRun(text: text, kind: kind)) } }
    private static func has(_ value: String, at index: Int, in characters: [Character]) -> Bool { let target = Array(value); guard index + target.count <= characters.count else { return false }; return Array(characters[index..<index + target.count]) == target }
    private static func find(_ value: String, in characters: [Character], from index: Int) -> Int? { guard index < characters.count else { return nil }; for candidate in index..<characters.count where has(value, at: candidate, in: characters) { return candidate }; return nil }
    private static func stringEnd(in characters: [Character], from index: Int, delimiter: Character) -> Int { var cursor = index + 1; var escaped = false; while cursor < characters.count { let current = characters[cursor]; if current == delimiter && !escaped { return cursor + 1 }; escaped = current == "\\" && !escaped; if current != "\\" { escaped = false }; cursor += 1 }; return characters.count }
    private static func isIdentifierStart(_ character: Character) -> Bool { character.isLetter || character == "_" || character == "$" }
    private static func isIdentifierPart(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" || character == "$" }
    private static func nextNonSpace(_ characters: [Character], after index: Int) -> Character? { characters.dropFirst(index).first(where: { !$0.isWhitespace }) }
}
