import Foundation

@main
enum HeadTailValidation {
    private enum Row: Equatable { case header(Int), match(Int, Int), path(String) }

    static func main() {
        let paths = (1...10).map { Row.path("p\($0)") }
        let even = slice(paths, maxLines: 4)
        precondition(even.hidden == 6)
        precondition(even.head == [.path("p1"), .path("p2")])
        precondition(even.tail == [.path("p9"), .path("p10")])

        let odd = slice((1...5).map { Row.path("p\($0)") }, maxLines: 1)
        precondition(odd.hidden == 4 && odd.head == [.path("p1")] && odd.tail.isEmpty)

        let grouped = [Row.header(0)] + (1...10).map { Row.match(0, $0) }
            + [Row.header(1)] + (11...20).map { Row.match(1, $0) }
        let restored = slice(grouped, maxLines: 8)
        precondition(restored.hidden == 14)
        precondition(restored.head == [.header(0), .match(0, 1), .match(0, 2), .match(0, 3)])
        precondition(restored.tailHeader == .header(1))
        precondition(restored.tail == [.match(1, 18), .match(1, 19), .match(1, 20)])
        precondition(restored.head.count + (restored.tailHeader == nil ? 0 : 1) + restored.tail.count == 8)

        let single = slice([Row.header(0)] + (1...10).map { Row.match(0, $0) }, maxLines: 4)
        precondition(single.tailHeader == nil)

        print("HeadTailValidation: 4 fixtures passed")
    }

    private static func slice(_ rows: [Row], maxLines: Int) -> HeadTailSlices<Row> {
        HeadTail.slices(rows, maxLines: maxLines, expanded: false, owner: { row in
            if case let .match(owner, _) = row { return owner }
            return nil
        }, isHeader: { row, owner in row == .header(owner) })
    }
}
