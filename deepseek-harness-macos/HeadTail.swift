struct HeadTailSlices<Element> {
    let hidden: Int
    let head: [Element]
    let tailHeader: Element?
    let tail: [Element]
}

enum HeadTail {
    static func slices<Element>(
        _ rows: [Element],
        maxLines: Int,
        expanded: Bool,
        owner: (Element) -> Int? = { _ in nil },
        isHeader: (Element, Int) -> Bool = { _, _ in false }
    ) -> HeadTailSlices<Element> {
        let limit = max(0, maxLines)
        let hidden = rows.count - limit
        guard hidden > 0, !expanded else {
            return HeadTailSlices(hidden: max(0, hidden), head: rows, tailHeader: nil, tail: [])
        }
        let headCount = (limit + 1) / 2
        let tailCount = limit - headCount
        let head = Array(rows.prefix(headCount))
        let naturalTail = Array(rows.suffix(tailCount))
        guard let first = naturalTail.first, let group = owner(first),
              !head.contains(where: { isHeader($0, group) }),
              let header = rows.first(where: { isHeader($0, group) })
        else { return HeadTailSlices(hidden: hidden, head: head, tailHeader: nil, tail: naturalTail) }
        return HeadTailSlices(hidden: hidden, head: head, tailHeader: header, tail: Array(naturalTail.dropFirst()))
    }
}
