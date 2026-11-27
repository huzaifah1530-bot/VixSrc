import AVFoundation
import Foundation

/// Matching caption and audio tracks by language. Stream tracks carry a
/// locale or language tag; side-loaded anime subtitles carry only a label
/// such as "English" or "Spanish - Latin America".
enum MediaLanguage {
    /// Languages offered in pickers even when the playing video has none.
    static let common = ["en", "ja", "es", "fr", "de", "it", "pt", "ar", "ko", "zh", "hi", "ru", "tr", "nl", "pl"]

    static func name(for code: String) -> String {
        let english = Locale(identifier: "en")
        return english.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// Two- or three-letter language code of a stream track.
    static func code(of option: AVMediaSelectionOption) -> String? {
        if let tag = option.extendedLanguageTag, let code = tag.split(separator: "-").first, !code.isEmpty {
            return normalize(String(code))
        }
        if let code = option.locale?.language.languageCode?.identifier { return normalize(code) }
        return code(fromLabel: option.displayName)
    }

    /// Best guess at the language a free-text label names.
    static func code(fromLabel label: String) -> String? {
        let lower = label.lowercased()
        let english = Locale(identifier: "en")
        if let hit = namedLanguages.first(where: { lower.contains($0.name) }) { return hit.code }
        let token = lower.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? lower
        if token.count == 2 || token.count == 3, english.localizedString(forLanguageCode: token) != nil {
            return normalize(token)
        }
        return nil
    }

    /// Every two-letter language with its English name, longest name first
    /// so "Portuguese" wins over anything shorter it contains.
    private static let namedLanguages: [(code: String, name: String)] = {
        let english = Locale(identifier: "en")
        return Locale.LanguageCode.isoLanguageCodes
            .map(\.identifier)
            .filter { $0.count == 2 }
            .compactMap { code -> (code: String, name: String)? in
                guard let name = english.localizedString(forLanguageCode: code)?.lowercased(), name.count > 3 else { return nil }
                return (code, name)
            }
            .sorted { $0.name.count > $1.name.count }
    }()

    static func matches(option: AVMediaSelectionOption, code: String) -> Bool {
        self.code(of: option) == normalize(code)
    }

    static func matches(label: String, code: String) -> Bool {
        let wanted = normalize(code)
        if let found = self.code(fromLabel: label) { return found == wanted }
        return false
    }

    /// ISO 639-2 codes some streams use, folded to their 639-1 form.
    static func normalize(_ code: String) -> String {
        let lower = code.lowercased()
        let map = ["eng": "en", "jpn": "ja", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
                   "ita": "it", "por": "pt", "ara": "ar", "kor": "ko", "chi": "zh", "zho": "zh", "hin": "hi",
                   "rus": "ru", "tur": "tr", "dut": "nl", "nld": "nl", "pol": "pl"]
        return map[lower] ?? lower
    }
}
