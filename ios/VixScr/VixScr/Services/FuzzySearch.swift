import Foundation

/// Direct port of the fuzzy title-matching engine in index.html
/// (normalizeForMatch, levenshteinDistance, editSimilarity,
/// bestWindowEditSimilarity, ngramDice, titleTokenScore, fuzzyScore,
/// rankAndFilterItemsForQuery, queryConfidenceThreshold, parseSearchQuery).
///
/// This exists so title search still works usefully even when a query has
/// typos, extra words, or an embedded year like "Batman 2022" — TMDB's own
/// `/search/multi` is fairly literal, so the JS app supplements it with this
/// local re-ranking / fallback layer, and we do the same here.
enum FuzzySearch {
    static func normalizeForMatch(_ value: String) -> String {
        let lowered = value.lowercased()
        let folded = lowered.folding(options: .diacriticInsensitive, locale: .current)
        let withAnd = folded.replacingOccurrences(of: "&", with: " and ")
        let cleaned = withAnd.replacingOccurrences(
            of: "[^a-z0-9]+", with: " ", options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    static func compactForMatch(_ value: String) -> String {
        normalizeForMatch(value).replacingOccurrences(of: " ", with: "")
    }

    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        var a = Array(normalizeForMatch(a))
        var b = Array(normalizeForMatch(b))
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if a.count > b.count { swap(&a, &b) }

        var previous = Array(0...a.count)
        for j in 1...b.count {
            var current = [j]
            for i in 1...a.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current.append(min(current[i - 1] + 1, previous[i] + 1, previous[i - 1] + cost))
            }
            previous = current
        }
        return previous[a.count]
    }

    static func editSimilarity(_ a: String, _ b: String) -> Double {
        let aa = normalizeForMatch(a)
        let bb = normalizeForMatch(b)
        guard !aa.isEmpty, !bb.isEmpty else { return 0 }
        if aa == bb { return 1 }
        let distance = Double(levenshteinDistance(aa, bb))
        return 1 - min(distance / Double(max(aa.count, bb.count, 1)), 1)
    }

    static func bestWindowEditSimilarity(_ query: String, _ target: String) -> Double {
        let q = compactForMatch(query)
        let t = compactForMatch(target)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t.contains(q) { return 1 }
        if q.contains(t), t.count >= 4 { return min(0.92, Double(t.count) / Double(q.count)) }

        if q.count > t.count {
            let distance = Double(levenshteinDistance(q, t))
            return 1 - min(distance / Double(max(q.count, t.count, 1)), 1)
        }

        var best = 0.0
        let minLen = max(2, Int(Double(q.count) * 0.72))
        let maxLen = min(t.count, Int(ceil(Double(q.count) * 1.35)))
        guard minLen <= maxLen else { return best }
        let tChars = Array(t)
        for len in minLen...maxLen {
            guard len > 0, len <= tChars.count else { continue }
            for i in 0...(tChars.count - len) {
                let sub = String(tChars[i..<(i + len)])
                let distance = Double(levenshteinDistance(q, sub))
                let sim = 1 - min(distance / Double(max(q.count, sub.count, 1)), 1)
                if sim > best { best = sim }
                if best >= 0.98 { return best }
            }
        }
        return best
    }

    static func ngramDice(_ a: String, _ b: String, n: Int = 2) -> Double {
        let aa = Array(compactForMatch(a))
        let bb = Array(compactForMatch(b))
        guard aa.count >= n, bb.count >= n else { return 0 }

        func makeGrams(_ chars: [Character]) -> [String: Int] {
            var out: [String: Int] = [:]
            for i in 0...(chars.count - n) {
                let key = String(chars[i..<(i + n)])
                out[key, default: 0] += 1
            }
            return out
        }

        let a = makeGrams(aa)
        let b = makeGrams(bb)
        var intersection = 0
        var total = 0
        total += a.values.reduce(0, +)
        total += b.values.reduce(0, +)
        for (key, count) in a {
            if let bCount = b[key] { intersection += min(count, bCount) }
        }
        return total > 0 ? (2 * Double(intersection)) / Double(total) : 0
    }

    static func queryConfidenceThreshold(_ query: String) -> Double {
        let compact = compactForMatch(query)
        if compact.count <= 2 { return 1.1 }
        if compact.count <= 3 { return 0.86 }
        if compact.count <= 5 { return 0.68 }
        if compact.count <= 8 { return 0.57 }
        return 0.52
    }

    static func titleTokenScore(_ query: String, _ title: String) -> Double {
        let qTokens = normalizeForMatch(query).split(separator: " ").map(String.init)
        let titleTokens = normalizeForMatch(title).split(separator: " ").map(String.init)
        guard !qTokens.isEmpty, !titleTokens.isEmpty else { return 0 }

        var total = 0.0
        for qToken in qTokens {
            var best = 0.0
            for titleToken in titleTokens {
                if qToken == titleToken { best = max(best, 1) }
                if titleToken.hasPrefix(qToken), qToken.count >= 2 { best = max(best, 0.94) }
                if titleToken.contains(qToken), qToken.count >= 3 { best = max(best, 0.88) }
                if qToken.contains(titleToken), titleToken.count >= 4 { best = max(best, 0.78) }
                if qToken.count >= 4 || titleToken.count >= 4 {
                    best = max(best, bestWindowEditSimilarity(qToken, titleToken) * 0.96)
                }
            }
            total += best
        }
        return total / Double(qTokens.count)
    }

    static func fuzzyScore(query: String, title: String) -> Double {
        let q = normalizeForMatch(query)
        let normalizedTitle = normalizeForMatch(title)
        guard !q.isEmpty, !normalizedTitle.isEmpty else { return 0 }

        let qCompact = compactForMatch(q)
        let titleCompact = compactForMatch(normalizedTitle)
        if normalizedTitle == q || titleCompact == qCompact { return 1.25 }
        if normalizedTitle.hasPrefix(q) { return 1.14 }
        if normalizedTitle.contains(q), qCompact.count >= 3 { return 1.04 }
        if titleCompact.contains(qCompact), qCompact.count >= 3 { return 1.02 }

        let variants = [
            normalizedTitle,
            normalizedTitle.split(separator: ":").first.map(String.init) ?? normalizedTitle,
            normalizedTitle.split(separator: "-").first.map(String.init) ?? normalizedTitle
        ]

        var best = 0.0
        for variant in variants {
            let compactSimilarity = editSimilarity(qCompact, compactForMatch(variant))
            let windowSimilarity = bestWindowEditSimilarity(q, variant)
            let tokenSimilarity = titleTokenScore(q, variant)
            let bigramSimilarity = ngramDice(q, variant, n: 2)
            let trigramSimilarity = ngramDice(q, variant, n: 3)
            best = max(
                best,
                compactSimilarity * 0.72,
                windowSimilarity * 0.98,
                tokenSimilarity * 0.95,
                bigramSimilarity * 0.82,
                trigramSimilarity * 0.9
            )
        }
        return best
    }

    struct ParsedQuery {
        var raw: String
        var year: String
        var titleQuery: String
    }

    /// Splits an embedded 4-digit year (1900-2099) out of the query, e.g.
    /// "Batman 2022" -> title "Batman", year "2022".
    static func parseSearchQuery(_ query: String) -> ParsedQuery {
        let raw = query.trimmingCharacters(in: .whitespaces)
        var year = ""
        var titleQuery = raw

        if let range = raw.range(of: #"(?:^|\s)((?:19|20)\d{2})(?:\s|$)"#, options: .regularExpression) {
            let match = String(raw[range]).trimmingCharacters(in: .whitespaces)
            year = match
            titleQuery = raw.replacingOccurrences(of: match, with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return ParsedQuery(raw: raw, year: year, titleQuery: titleQuery.isEmpty ? raw : titleQuery)
    }

    static func yearAdjustedScore(query: String, item: MediaItem, wantedYear: String) -> Double {
        var score = fuzzyScore(query: query, title: item.title)
        if !wantedYear.isEmpty {
            if item.year == wantedYear { score += 0.32 }
            else if !item.year.isEmpty { score -= 0.18 }
        }
        return score
    }

    /// Ranks and filters `items` against `query`, mirroring
    /// `rankAndFilterItemsForQuery`. Returns items sorted best-first, with
    /// popularity as a tiebreaker when scores are close.
    static func rankAndFilter(items: [MediaItem], query: String, year: String = "", threshold: Double? = nil) -> [MediaItem] {
        let effectiveThreshold = threshold ?? queryConfidenceThreshold(query)
        guard compactForMatch(query).count >= 2 else { return [] }

        return items
            .map { ($0, yearAdjustedScore(query: query, item: $0, wantedYear: year)) }
            .filter { $0.1 >= effectiveThreshold }
            .sorted { a, b in
                // diff = b.score - a.score; positive means b scores higher.
                // Return true when a should sort before b, i.e. a.score > b.score.
                let diff = b.1 - a.1
                if abs(diff) > 0.04 { return diff > 0 }   // was diff < 0 — inverted, best results were last
                return a.0.popularity > b.0.popularity
            }
            .map(\.0)
    }
}
