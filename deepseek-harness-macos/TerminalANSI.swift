import AppKit
import SwiftUI

struct TerminalANSIOutput {
    let lines: [TerminalANSILine]

    var isEmpty: Bool {
        lines.allSatisfy { line in
            line.spans.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}

struct TerminalANSILine {
    let spans: [TerminalANSISpan]

    var plainText: String { spans.map(\.text).joined() }

    var attributedString: AttributedString {
        guard !spans.isEmpty else { return AttributedString(" ") }
        return spans.reduce(into: AttributedString()) { result, span in
            var piece = AttributedString(span.text)
            var foreground = span.style.foregroundColor
            if span.style.dim { foreground = foreground.opacity(0.7) }
            if span.style.hidden { foreground = .clear }
            piece.foregroundColor = foreground
            if let background = span.style.backgroundColor { piece.backgroundColor = background }
            var font = Font.system(size: 12, design: .monospaced)
            if span.style.bold { font = font.bold() }
            if span.style.italic { font = font.italic() }
            piece.font = font
            if span.style.underline { piece.underlineStyle = .single }
            if span.style.strikethrough { piece.strikethroughStyle = .single }
            result.append(piece)
        }
    }
}

struct TerminalANSISpan {
    let text: String
    let style: TerminalANSIStyle
}

struct TerminalANSIStyle: Equatable {
    fileprivate var foreground: TerminalANSIColor?
    fileprivate var background: TerminalANSIColor?
    var bold = false
    fileprivate var dim = false
    var italic = false
    fileprivate var underline = false
    fileprivate var strikethrough = false
    fileprivate var hidden = false
    fileprivate var reversed = false

    fileprivate var foregroundColor: Color {
        if reversed { return (background ?? .literal(0, 0, 0)).literalColor }
        guard let foreground else { return .primary }
        return background == nil ? foreground.semanticColor : foreground.literalColor
    }

    fileprivate var backgroundColor: Color? {
        if reversed { return (foreground ?? .literal(255, 255, 255)).literalColor }
        return background?.literalColor
    }
}

private enum TerminalANSIColor: Equatable {
    case primary(UInt8, UInt8, UInt8)
    case tertiary(UInt8, UInt8, UInt8)
    case errorPrimary(UInt8, UInt8, UInt8)
    case errorSecondary(UInt8, UInt8, UInt8)
    case successPrimary(UInt8, UInt8, UInt8)
    case successSecondary(UInt8, UInt8, UInt8)
    case warningPrimary(UInt8, UInt8, UInt8)
    case warningSecondary(UInt8, UInt8, UInt8)
    case business(UInt8, UInt8, UInt8)
    case staticBlue(UInt8, UInt8, UInt8)
    case literal(UInt8, UInt8, UInt8)

    var components: (UInt8, UInt8, UInt8) {
        switch self {
        case let .primary(r, g, b), let .tertiary(r, g, b), let .errorPrimary(r, g, b),
             let .errorSecondary(r, g, b), let .successPrimary(r, g, b),
             let .successSecondary(r, g, b), let .warningPrimary(r, g, b),
             let .warningSecondary(r, g, b), let .business(r, g, b),
             let .staticBlue(r, g, b), let .literal(r, g, b): return (r, g, b)
        }
    }

    var literalColor: Color {
        let (r, g, b) = components
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    var semanticColor: Color {
        switch self {
        case .primary: return Color(nsColor: .labelColor)
        case .tertiary: return Color(nsColor: .tertiaryLabelColor)
        case .errorPrimary: return Color(nsColor: .systemRed)
        case .errorSecondary: return Color(nsColor: .systemRed).opacity(0.78)
        case .successPrimary: return Color(nsColor: .systemGreen)
        case .successSecondary: return Color(nsColor: .systemGreen).opacity(0.78)
        case .warningPrimary: return Color(nsColor: .systemOrange)
        case .warningSecondary: return Color(nsColor: .systemYellow)
        case .business: return Color(nsColor: Theme.blue)
        case .staticBlue: return Color(red: 85 / 255, green: 85 / 255, blue: 1)
        case .literal: return literalColor
        }
    }
}

enum TerminalANSIParser {
    private struct Cell {
        var character: String
        var style: TerminalANSIStyle
        var spacer = false
    }

    static func parse(_ raw: String) -> TerminalANSIOutput {
        let characters = Array(raw)
        var index = 0
        var cursor = 0
        var cells: [Cell?] = []
        var style = TerminalANSIStyle()
        var lines: [TerminalANSILine] = []

        func ensure(_ position: Int) {
            if cells.count <= position { cells.append(contentsOf: repeatElement(nil, count: position - cells.count + 1)) }
        }

        func clear(_ position: Int, fill: String = " ") {
            guard position >= 0 else { return }
            ensure(position)
            if cells[position]?.spacer == true, position > 0 { cells[position - 1] = Cell(character: fill, style: style) }
            if let cell = cells[position], isWide(cell.character), position + 1 < cells.count, cells[position + 1]?.spacer == true {
                cells[position + 1] = Cell(character: fill, style: style)
            }
            cells[position] = Cell(character: fill, style: style)
        }

        func write(_ character: Character) {
            if character == "\t" {
                let stop = cursor + 8 - cursor % 8
                while cursor < stop {
                    ensure(cursor)
                    if cells[cursor] == nil { cells[cursor] = Cell(character: " ", style: style) }
                    cursor += 1
                }
                return
            }
            let value = String(character)
            if isZeroWidth(character) {
                if cursor > 0, let base = cells.indices.contains(cursor - 1) ? cells[cursor - 1] : nil {
                    cells[cursor - 1] = Cell(character: base.character + value, style: base.style, spacer: base.spacer)
                }
                return
            }
            clear(cursor, fill: " ")
            cells[cursor] = Cell(character: value, style: style)
            cursor += 1
            if isWide(value) {
                ensure(cursor)
                cells[cursor] = Cell(character: "", style: style, spacer: true)
                cursor += 1
            }
        }

        func finishLine() {
            var spans: [TerminalANSISpan] = []
            var activeStyle: TerminalANSIStyle?
            var text = ""
            for position in cells.indices {
                let cell = cells[position] ?? Cell(character: " ", style: TerminalANSIStyle())
                let leadIntact = position > 0 && isWide(cells[position - 1]?.character ?? "")
                let character = cell.spacer && leadIntact ? "" : (cell.spacer ? " " : cell.character)
                guard !character.isEmpty else { continue }
                if activeStyle == cell.style { text += character }
                else {
                    if let activeStyle, !text.isEmpty { spans.append(TerminalANSISpan(text: text, style: activeStyle)) }
                    activeStyle = cell.style
                    text = character
                }
            }
            if let activeStyle, !text.isEmpty { spans.append(TerminalANSISpan(text: text, style: activeStyle)) }
            lines.append(TerminalANSILine(spans: spans))
            cells = []
            cursor = 0
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\n" { finishLine(); index += 1; continue }
            if character == "\r" { cursor = 0; index += 1; continue }
            if character == "\u{8}" { cursor = max(0, cursor - 1); index += 1; continue }
            if character == "\u{1B}" {
                guard index + 1 < characters.count else { index += 1; continue }
                if characters[index + 1] == "]" {
                    index += 2
                    while index < characters.count {
                        if characters[index] == "\u{7}" { index += 1; break }
                        if characters[index] == "\u{1B}", index + 1 < characters.count, characters[index + 1] == "\\" { index += 2; break }
                        index += 1
                    }
                    continue
                }
                if characters[index + 1] == "[" {
                    index += 2
                    var parameters = ""
                    while index < characters.count {
                        guard let scalar = characters[index].unicodeScalars.first?.value else { index += 1; continue }
                        if scalar >= 0x40 && scalar <= 0x7E { break }
                        if scalar >= 0x30 && scalar <= 0x3F { parameters.append(characters[index]) }
                        index += 1
                    }
                    guard index < characters.count else { break }
                    let final = characters[index]
                    index += 1
                    if final == "m" { applySGR(parameters, to: &style) }
                    else if final == "K" {
                        let mode = Int(parameters.split(separator: ";", omittingEmptySubsequences: false).first ?? "0") ?? 0
                        if mode == 1 {
                            if cursor >= 0 { for position in 0...cursor { clear(position) } }
                        } else if mode == 2 { cells.removeAll(keepingCapacity: true) }
                        else if cursor < cells.count { cells.removeSubrange(cursor..<cells.count) }
                    }
                    continue
                }
                index += 1
                while index < characters.count,
                      let scalar = characters[index].unicodeScalars.first?.value,
                      scalar >= 0x20 && scalar <= 0x2F { index += 1 }
                if index < characters.count,
                   let scalar = characters[index].unicodeScalars.first?.value,
                   scalar >= 0x30 && scalar <= 0x7E { index += 1 }
                continue
            }
            if let scalar = character.unicodeScalars.first?.value,
               (scalar < 0x20 && character != "\t") || scalar == 0x7F { index += 1; continue }
            write(character)
            index += 1
        }
        finishLine()
        if lines.count > 1, lines.last?.spans.isEmpty == true { lines.removeLast() }
        return TerminalANSIOutput(lines: lines)
    }

    private static func applySGR(_ parameters: String, to style: inout TerminalANSIStyle) {
        let values = parameters.isEmpty ? [0] : parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: style = TerminalANSIStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.reversed = true
            case 8: style.hidden = true
            case 9: style.strikethrough = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.reversed = false
            case 28: style.hidden = false
            case 29: style.strikethrough = false
            case 30...37, 90...97: style.foreground = basicColor(code)
            case 39: style.foreground = nil
            case 40...47, 100...107: style.background = basicColor(code - 10)
            case 49: style.background = nil
            case 38, 48:
                let foreground = code == 38
                if index + 2 < values.count, values[index + 1] == 5 {
                    let color = paletteColor(values[index + 2])
                    if foreground { style.foreground = color } else { style.background = color }
                    index += 2
                } else if index + 4 < values.count, values[index + 1] == 2 {
                    let color = TerminalANSIColor.literal(byte(values[index + 2]), byte(values[index + 3]), byte(values[index + 4]))
                    if foreground { style.foreground = color } else { style.background = color }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private static func basicColor(_ code: Int) -> TerminalANSIColor {
        switch code {
        case 30, 37, 97: return .primary(code == 30 ? 0 : 255, code == 30 ? 0 : 255, code == 30 ? 0 : 255)
        case 90: return .tertiary(85, 85, 85)
        case 31: return .errorPrimary(187, 0, 0)
        case 91: return .errorSecondary(255, 85, 85)
        case 32: return .successPrimary(0, 187, 0)
        case 92: return .successSecondary(0, 255, 0)
        case 33: return .warningPrimary(187, 187, 0)
        case 93: return .warningSecondary(255, 255, 85)
        case 34: return .business(0, 0, 187)
        case 94: return .staticBlue(85, 85, 255)
        case 35: return .literal(187, 0, 187)
        case 95: return .literal(255, 85, 255)
        case 36: return .literal(0, 187, 187)
        case 96: return .literal(85, 255, 255)
        default: return .literal(255, 255, 255)
        }
    }

    private static func paletteColor(_ value: Int) -> TerminalANSIColor {
        let palette: [(UInt8, UInt8, UInt8)] = [
            (0,0,0),(187,0,0),(0,187,0),(187,187,0),(0,0,187),(187,0,187),(0,187,187),(255,255,255),
            (85,85,85),(255,85,85),(0,255,0),(255,255,85),(85,85,255),(255,85,255),(85,255,255),(255,255,255),
        ]
        if value >= 0 && value < 16 { let rgb = palette[value]; return .literal(rgb.0, rgb.1, rgb.2) }
        if value >= 16 && value <= 231 {
            let cube: [UInt8] = [0, 95, 135, 175, 215, 255]
            let offset = value - 16
            return .literal(cube[offset / 36], cube[(offset / 6) % 6], cube[offset % 6])
        }
        let gray = byte(8 + max(0, min(23, value - 232)) * 10)
        return .literal(gray, gray, gray)
    }

    private static func byte(_ value: Int) -> UInt8 { UInt8(max(0, min(255, value))) }

    private static func isZeroWidth(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return true
        default: return false
        }
    }

    private static func isWide(_ value: String) -> Bool {
        guard let scalar = value.unicodeScalars.first?.value, scalar >= 0x1100 else { return false }
        return (0x1100...0x115F).contains(scalar) || (0x2E80...0xA4CF).contains(scalar)
            || (0xAC00...0xD7A3).contains(scalar) || (0xF900...0xFAFF).contains(scalar)
            || (0xFE10...0xFE6F).contains(scalar) || (0xFF01...0xFF60).contains(scalar)
            || (0x1F300...0x1FAFF).contains(scalar)
    }
}
