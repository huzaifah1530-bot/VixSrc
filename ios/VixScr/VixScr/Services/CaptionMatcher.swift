import AVFoundation
import Foundation

/// Picks the caption track in an episode that best fits a title's default
/// caption, with a confidence from 0 to 1, because track names change from
/// episode to episode ("English", "English CC", "English [SDH]", "Signs &
/// Songs"):
///   - 1.0  the exact track name it was picked from
///   - 0.95 the same name, ignoring case, brackets and punctuation
///   - 0.7  any track in the language, +0.2 for names that look alike
///   - forced / signs-only tracks lose 0.45 unless one was picked, so they
///     never win over full captions at the default threshold
///   - CC / SDH versus plain loses 0.1, commentary or descriptions lose 0.4
enum CaptionMatcher {
    struct Candidate {
        let label: String
        let code: String?
        let isForced: Bool
    }

    struct Match: Equatable, Sendable {
        let index: Int
        let label: String
        let confidence: Double
    }

    static func candidate(_ option: AVMediaSelectionOption) -> Candidate {
        Candidate(label: option.displayName, code: MediaLanguage.code(of: option),
                  isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
    }

    static func candidate(label: String) -> Candidate {
        Candidate(label: label, code: MediaLanguage.code(fromLabel: label), isForced: false)
    }

    static func best(_ candidates: [Candidate], code: String, label: String?, minimum: Double) -> Match? {
        candidates.enumerated()
            .map { Match(index: $0.offset, label: $0.element.label, confidence: score($0.element, code: code, label: label)) }
            .filter { $0.confidence >= minimum && $0.confidence > 0 }
            .max { $0.confidence < $1.confidence }
    }

    static func score(_ candidate: Candidate, code: String, label wanted: String?) -> Double {
        let wantedCode = MediaLanguage.normalize(code)
        if let wanted, candidate.label == wanted { return 1 }
        if let wanted, normalized(candidate.label) == normalized(wanted), !normalized(wanted).isEmpty { return 0.95 }
        guard let found = candidate.code, MediaLanguage.normalize(found) == wantedCode else { return 0 }

        var score = 0.7
        let candidateTokens = tokens(candidate.label, dropping: wantedCode)
        let wantedTokens = tokens(wanted ?? "", dropping: wantedCode)
        if !wantedTokens.isEmpty || !candidateTokens.isEmpty {
            let union = wantedTokens.union(candidateTokens)
            let shared = wantedTokens.intersection(candidateTokens)
            score += 0.2 * Double(shared.count) / Double(max(1, union.count))
        } else {
            // Both just the language name.
            score += 0.2
        }

        let wantedText = (wanted ?? "").lowercased()
        let text = candidate.label.lowercased()
        let forced = candidate.isForced || hasAny(text, ["forced", "signs", "songs", "sign "])
        let wantedForced = hasAny(wantedText, ["forced", "signs", "songs", "sign "])
        if forced != wantedForced { score -= 0.45 }
        if hasAny(text, ["sdh", "cc", "hearing"]) != hasAny(wantedText, ["sdh", "cc", "hearing"]) { score -= 0.1 }
        if hasAny(text, ["commentary", "description", "described"]) && !hasAny(wantedText, ["commentary", "description", "described"]) {
            score -= 0.4
        }
        return min(0.94, max(0.01, score))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Words in a track name other than the language's own name.
    private static func tokens(_ text: String, dropping code: String) -> Set<String> {
        let language = MediaLanguage.name(for: code).lowercased()
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0 != language && $0 != code && $0.count > 1 })
    }

    private static func hasAny(_ text: String, _ needles: [String]) -> Bool {
        let padded = " " + text.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression) + " "
        return needles.contains { padded.contains(" " + $0.trimmingCharacters(in: .whitespaces) + " ") }
    }
}
