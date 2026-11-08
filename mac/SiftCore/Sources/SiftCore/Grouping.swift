import Foundation

public enum Grouping {
    public static let reasons: [MatchKind: String] = [
        .identical: "Identical copy of the one marked Keep",
        .same: "Same photo as the one marked Keep, saved again or resized",
        .similar: "A similar shot taken around the same time — check before deleting",
        .lookalike: "Looks the same as the one marked Keep but has a different date — check it's a copy",
    ]
    public static let linkedReason = "Looks like another photo in this set — check before deleting"

    /// Groups matching photos into sets, picks the one to keep in each (the highest
    /// resolution, preferring RAW, favourites, edited and Live Photos, then ones on this Mac,
    /// then the largest file), and suggests what to do with the rest. Copies are suggested
    /// for deleting, unless they're favourites; everything else is for review. The sets
    /// with the most space to free come first.
    public static func buildSets(_ items: [PhotoItem], matches: [Match]) -> [DuplicateSet] {
        var parent = Array(items.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var kinds: [Int: [Int: MatchKind]] = [:]
        for m in matches {
            parent[find(m.a)] = find(m.b)
            kinds[m.a, default: [:]][m.b] = m.kind
            kinds[m.b, default: [:]][m.a] = m.kind
        }
        var clusters: [Int: [Int]] = [:]
        for i in Set(matches.flatMap { [$0.a, $0.b] }).sorted() {
            clusters[find(i), default: []].append(i)
        }

        func better(_ x: Int, than y: Int) -> Bool {
            let a = items[x], b = items[y]
            let ka: [Int] = [a.pixels, a.raw ? 1 : 0, a.favorite ? 1 : 0, a.edited ? 1 : 0, a.live ? 1 : 0, a.cloudOnly ? 0 : 1]
            let kb: [Int] = [b.pixels, b.raw ? 1 : 0, b.favorite ? 1 : 0, b.edited ? 1 : 0, b.live ? 1 : 0, b.cloudOnly ? 0 : 1]
            if ka != kb { return ka.lexicographicallyPrecedes(kb) == false }
            return a.size > b.size
        }

        var sets: [DuplicateSet] = []
        for members in clusters.values {
            let keeper = members.reduce(members[0]) { better($1, than: $0) ? $1 : $0 }
            var rest: [SetMember] = []
            for m in members where m != keeper {
                let kind = kinds[m]?[keeper]
                if let kind, kind == .identical || kind == .same {
                    rest.append(items[m].favorite
                        ? SetMember(index: m, suggestion: .review, reason: reasons[kind]! + " (but it's a favourite)")
                        : SetMember(index: m, suggestion: .delete, reason: reasons[kind]!))
                } else {
                    rest.append(SetMember(index: m, suggestion: .review, reason: kind.flatMap { reasons[$0] } ?? linkedReason))
                }
            }
            rest.sort { ($0.suggestion == .delete ? 0 : 1, -items[$0.index].size) < ($1.suggestion == .delete ? 0 : 1, -items[$1.index].size) }
            sets.append(DuplicateSet(members: [SetMember(index: keeper, suggestion: .keep,
                                                         reason: "Best copy: highest resolution")] + rest))
        }
        return sets.sorted { ($0.saving(items), $0.members.count) > ($1.saving(items), $1.members.count) }
    }
}
