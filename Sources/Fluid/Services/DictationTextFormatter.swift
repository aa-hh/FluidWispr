import Foundation

/// Formats dictated text in two passes. `clean` runs on the raw transcript (filler words, custom
/// dictionary, spoken punctuation). `finalize` runs last, after any AI cleanup (literal commands and
/// mentions, GAAV, continuous dictation, terminal autocomplete spacing).
///
/// Settings and app context come in as values, so callers read `SettingsStore` once per dictation
/// and tests need no stored settings.
enum DictationTextFormatter {
    struct Settings: Equatable {
        var removesFillerWords = false
        var fillerWords: [String] = []
        var customDictionaryEntries: [SettingsStore.CustomDictionaryEntry] = []
        var convertsSpokenPunctuation = false
        var punctuationPrefix = SettingsStore.defaultPunctuationDictionaryPrefix
        var punctuationRules: [SettingsStore.PunctuationDictionaryRule] = []
        var spokenActionRules: [SettingsStore.SpokenFormattingActionRule] = []
        var formatsLiterals = false
        var gaavRemovesTrailingPeriod = false
        var gaavLowercasesFirstLetter = false
        var addsContinuousDictationSpacing = false
        var capitalizesFromContext = false

        /// The stored settings `clean` reads. Lists for steps that are off are left empty.
        static var currentForClean: Settings {
            let store = SettingsStore.shared
            let removesFillerWords = store.removeFillerWordsEnabled
            let convertsSpokenPunctuation = store.autoConvertPunctuationEnabled
            return Settings(
                removesFillerWords: removesFillerWords,
                fillerWords: removesFillerWords ? store.fillerWords : [],
                customDictionaryEntries: store.customDictionaryEntries,
                convertsSpokenPunctuation: convertsSpokenPunctuation,
                punctuationPrefix: convertsSpokenPunctuation
                    ? store.punctuationDictionaryPrefix
                    : SettingsStore.defaultPunctuationDictionaryPrefix,
                punctuationRules: convertsSpokenPunctuation ? store.punctuationDictionaryRules : [],
                spokenActionRules: convertsSpokenPunctuation ? store.spokenFormattingActionRules : []
            )
        }

        /// The stored settings `finalize` reads.
        static var currentForFinalize: Settings {
            let store = SettingsStore.shared
            return Settings(
                formatsLiterals: store.literalDictationFormattingEnabled,
                gaavRemovesTrailingPeriod: store.gaavRemoveTrailingPeriodEnabled,
                gaavLowercasesFirstLetter: store.gaavLowercaseFirstLetterEnabled,
                addsContinuousDictationSpacing: store.continuousDictationSpacingEnabled,
                capitalizesFromContext: store.contextAwareCapitalizationEnabled
            )
        }
    }

    /// The app the text goes to. Some steps only apply in chat, terminal or coding apps.
    struct AppContext: Equatable {
        var appName: String?
        var bundleID: String?
        var windowTitle: String?

        static let none = AppContext()
    }

    static func clean(_ text: String, context: AppContext = .none, settings: Settings) -> String {
        let withoutFillers = self.removeFillerWords(text, settings: settings)
        let dictionaryText = self.applyCustomDictionary(withoutFillers, settings: settings)
        return self.applySpokenPunctuation(dictionaryText, context: context, settings: settings)
    }

    /// `precedingText` is the text before the cursor when recording started; continuous
    /// dictation uses it for spacing and capitalization.
    static func finalize(
        _ text: String,
        context: AppContext = .none,
        precedingText: String,
        settings: Settings
    ) -> String {
        let literalText = self.applyLiteralFormatting(text, context: context, settings: settings)
        let gaavText = self.applyGAAVFormatting(literalText, settings: settings)
        let chainedText = self.applyContinuousDictationFormatting(
            gaavText,
            precedingText: precedingText,
            settings: settings
        )
        return self.applyTerminalLiteralAutocompleteSpacing(chainedText, context: context, settings: settings)
    }

    // MARK: - Filler words

    static func removeFillerWords(_ text: String, settings: Settings) -> String {
        guard settings.removesFillerWords else { return text }

        let fillers = Set(settings.fillerWords.map { $0.lowercased() })

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let filtered = words.filter { word in
            !fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }

        return filtered.joined(separator: " ")
    }

    // MARK: - Custom dictionary (cached regex)

    /// Key: trigger word. Holds the compiled regex and the escaped replacement template.
    private struct CachedDictionaryPattern {
        let entryID: UUID
        let trigger: String
        let regex: NSRegularExpression
        let template: String
        let canonical: NSRegularExpression?
    }

    private static var cachedDictionaryPatterns: [CachedDictionaryPattern] = []
    /// The entries the cache was built from.
    private static var cachedDictionaryEntries: [SettingsStore.CustomDictionaryEntry] = []
    private static var dictionaryCacheIsStale = true

    private static func rebuildDictionaryCache(for entries: [SettingsStore.CustomDictionaryEntry]) {
        var patterns: [CachedDictionaryPattern] = []

        for entry in entries {
            var canonical: NSRegularExpression?
            let replacementRange = NSRange(entry.replacement.startIndex..., in: entry.replacement)
            for trigger in entry.triggers {
                guard !trigger.isEmpty else { continue }

                let consumesHorizontalSeparators = !entry.replacement.isEmpty &&
                    entry.replacement.allSatisfy(\.isWhitespace)
                let escapedTrigger = self.dictionaryPattern(
                    for: trigger,
                    consumesHorizontalSeparators: consumesHorizontalSeparators
                )
                guard let regex = try? NSRegularExpression(
                    pattern: escapedTrigger,
                    options: .caseInsensitive
                ) else { continue }

                let needsProtection = regex.matches(in: entry.replacement, range: replacementRange).contains {
                    $0.range.length < replacementRange.length
                }
                if needsProtection, canonical == nil {
                    canonical = try? NSRegularExpression(pattern: self.dictionaryPattern(for: entry.replacement), options: .caseInsensitive)
                }
                patterns.append(CachedDictionaryPattern(
                    entryID: entry.id,
                    trigger: trigger,
                    regex: regex,
                    template: NSRegularExpression.escapedTemplate(for: entry.replacement),
                    canonical: needsProtection ? canonical : nil
                ))
            }
        }

        self.cachedDictionaryPatterns = patterns.sorted {
            $0.regex.pattern.utf16.count > $1.regex.pattern.utf16.count
        }
        self.cachedDictionaryEntries = entries
        self.dictionaryCacheIsStale = false
    }

    private static func dictionaryPattern(
        for trigger: String,
        consumesHorizontalSeparators: Bool = false
    ) -> String {
        let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
        let prefix = self.startsWithWordCharacter(trigger) ? "\\b" : ""
        let suffix = self.endsWithWordCharacter(trigger) ? "\\b" : ""
        let separator = consumesHorizontalSeparators ? "[ \\t]*" : ""
        return separator + prefix + escapedTrigger + suffix + separator
    }

    private static func startsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return self.isWordCharacter(scalar)
    }

    private static func endsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return self.isWordCharacter(scalar)
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    static func invalidateDictionaryCache() {
        self.dictionaryCacheIsStale = true
    }

    /// Replaces trigger words and phrases with their replacements, case-insensitively and on word
    /// boundaries. The compiled regexes are reused until the entries change.
    static func applyCustomDictionary(_ text: String, settings: Settings) -> String {
        let entries = settings.customDictionaryEntries
        guard !entries.isEmpty else { return text }

        if self.dictionaryCacheIsStale || self.cachedDictionaryEntries != entries {
            self.rebuildDictionaryCache(for: entries)
        }

        guard !self.cachedDictionaryPatterns.isEmpty else {
            return text
        }

        var result = text

        var replacementCount = 0
        for pattern in self.cachedDictionaryPatterns {
            result = DictionaryReplacementProtection.replacingMatches(
                in: result,
                regex: pattern.regex,
                template: pattern.template,
                canonical: pattern.canonical,
                onReplacement: { range, heard, replacement in
                    replacementCount += 1
                    guard replacementCount <= DictionaryReplacementDiagnostics.maximumEvents else { return }
                    DebugLogger.shared.debug(
                        "DICTIONARY_REPLACEMENT stage=exact_rule entryID=\(pattern.entryID) " +
                            "trigger=\(DictionaryReplacementDiagnostics.quoted(pattern.trigger)) " +
                            "heard=\(DictionaryReplacementDiagnostics.quoted(heard)) " +
                            "replacement=\(DictionaryReplacementDiagnostics.quoted(replacement)) " +
                            "utf16Location=\(range.location) utf16Length=\(range.length)",
                        source: "CustomDictionary"
                    )
                }
            )
        }
        if replacementCount > DictionaryReplacementDiagnostics.maximumEvents {
            DebugLogger.shared.info(
                "DICTIONARY_REPLACEMENT_SUMMARY total=\(replacementCount) " +
                    "omitted=\(replacementCount - DictionaryReplacementDiagnostics.maximumEvents)",
                source: "CustomDictionary"
            )
        }

        return result
    }

    // MARK: - GAAV mode

    /// Removes first letter capitalization and the trailing period, for search boxes, form fields
    /// and casual text. Feature requested by maxgaav.
    static func applyGAAVFormatting(_ text: String, settings: Settings) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        if settings.gaavRemovesTrailingPeriod, result.hasSuffix(".") {
            result.removeLast()
        }

        if settings.gaavLowercasesFirstLetter, let first = result.first, first.isUppercase {
            result = first.lowercased() + result.dropFirst()
        }

        return result
    }

    // MARK: - Continuous dictation

    /// Chains dictated segments: a space between them and capitalization that follows the text
    /// before the cursor. Each part has its own setting. From GitHub issue #390.
    static func applyContinuousDictationFormatting(
        _ text: String,
        precedingText: String,
        settings: Settings
    ) -> String {
        guard !text.isEmpty else { return text }
        let spacingEnabled = settings.addsContinuousDictationSpacing
        let smartCapsEnabled = settings.capitalizesFromContext
        guard spacingEnabled || smartCapsEnabled else { return text }

        var result = text

        if smartCapsEnabled {
            let precedingTrimmed = precedingText.trimmingCharacters(in: .whitespaces)
            let boundaryCharacter = self.lastCapitalizationBoundaryCharacter(in: precedingTrimmed)
            if boundaryCharacter == nil || boundaryCharacter?.isSentenceEndingPunctuation == true {
                result = self.replacingFirstLetter(in: result, transform: { $0.uppercased() })
            } else {
                result = self.replacingFirstLetter(in: result, transform: { $0.lowercased() })
            }
        }

        if spacingEnabled {
            if let lastPreceding = precedingText.last,
               !lastPreceding.isWhitespace,
               result.first?.isWhitespace != true
            {
                result = " " + result
            }

            if result.last?.isWhitespace != true {
                result += " "
            }
        }

        return result
    }

    private static func lastCapitalizationBoundaryCharacter(in text: String) -> Character? {
        for character in text.reversed() {
            if character.isNewline {
                return nil
            }
            if character.isHorizontalWhitespace || character.isClosingPunctuationWrapper {
                continue
            }
            return character
        }
        return nil
    }

    private static func replacingFirstLetter(in text: String, transform: (Character) -> String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        let nextIndex = text.index(after: index)
        return String(text[..<index]) + transform(text[index]) + String(text[nextIndex...])
    }
}

private extension Character {
    var isSentenceEndingPunctuation: Bool {
        self == "." || self == "!" || self == "?"
    }

    var isHorizontalWhitespace: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    var isClosingPunctuationWrapper: Bool {
        switch self {
        case "\"", "'", "”", "’", "»", "›", ")", "]", "}", "」", "』":
            return true
        default:
            return false
        }
    }
}
