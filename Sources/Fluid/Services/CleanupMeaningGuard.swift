import Foundation

/// Checks an AI cleanup against the transcript it came from. Cleanup models
/// sometimes drop a "not" or change a number, which flips what was said, so a
/// cleanup that does either is replaced by the rule-cleaned transcript.
///
/// Numbers are compared as one string of digits in reading order, with spoken
/// numbers read as digits on both sides: "five thirty" and "5:30" both read
/// "530", "twelve fifty" and "$12.50" both read "1250". That lets the model
/// format numbers freely without hiding a changed or invented one.
nonisolated enum CleanupMeaningGuard {
    enum Violation: Equatable {
        case negations(transcript: Int, cleaned: Int)
        case numbers(transcriptDigits: Int, cleanedDigits: Int)

        /// Counts only, so the log never holds what was said.
        var logDescription: String {
            switch self {
            case let .negations(transcript, cleaned):
                return "reason=negations transcript=\(transcript) cleaned=\(cleaned)"
            case let .numbers(transcriptDigits, cleanedDigits):
                return "reason=numbers transcriptDigits=\(transcriptDigits) cleanedDigits=\(cleanedDigits)"
            }
        }

        var historyReason: String {
            switch self {
            case .negations:
                return "AI cleanup added or removed a \"not\", so the transcript was pasted instead."
            case .numbers:
                return "AI cleanup changed a number, so the transcript was pasted instead."
            }
        }
    }

    /// Nil when the cleanup kept every negation and number. A speaker who
    /// corrects themselves ("actually", "scratch that") may lose a negation or
    /// number on purpose, so then only additions and changes count. Negations said
    /// twice in a row ("I don't, I don't think") may lose the repeat.
    static func check(transcript: String, cleaned: String) -> Violation? {
        let spoken = self.words(in: transcript)
        let spokenOnce = self.removingRepeats(spoken)
        let written = self.words(in: cleaned)
        let corrected = self.hasCorrectionPhrase(spoken) || self.hasCommaCueCorrection(transcript)

        let writtenNegations = self.negationCount(written)
        let spokenNegations = self.negationCount(spoken)
        let requiredNegations = corrected ? 0 : self.negationCount(spokenOnce)
        if writtenNegations > spokenNegations || writtenNegations < requiredNegations {
            return .negations(transcript: spokenNegations, cleaned: writtenNegations)
        }

        let writtenDigits = self.numberDigits(written)
        let spokenDigits = self.numberDigits(spoken)
        // Repeats are kept for numbers: "four four two" must not pass as 42.
        if writtenDigits == spokenDigits || (corrected && self.isSubsequence(writtenDigits, of: spokenDigits)) {
            return nil
        }
        return .numbers(transcriptDigits: spokenDigits.count, cleanedDigits: writtenDigits.count)
    }

    // MARK: - Words

    /// Lowercased words. Apostrophes stay inside words ("don't"), and ".", ","
    /// and ":" stay inside numbers ("5:30", "1,000").
    static func words(in text: String) -> [String] {
        let characters = Array(text.lowercased())
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "\u{2019}" {
                if !current.isEmpty { current.append("'") }
            } else if ".,:".contains(character),
                      current.last?.isNumber == true,
                      index + 1 < characters.count, characters[index + 1].isNumber
            {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                current = ""
            }
        }
        if !current.isEmpty {
            words.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        }
        return words.filter { !$0.isEmpty }
    }

    /// Drops the first copy of any run of one to four words said twice in a row.
    static func removingRepeats(_ words: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < words.count {
            var skipped = false
            for length in stride(from: 4, through: 1, by: -1) where index + 2 * length <= words.count {
                if words[index ..< index + length] == words[index + length ..< index + 2 * length] {
                    index += length
                    skipped = true
                    break
                }
            }
            if !skipped {
                kept.append(words[index])
                index += 1
            }
        }
        return kept
    }

    private static let correctionPhrases: [[String]] = [
        ["actually"], ["scratch", "that"], ["delete", "that"], ["no", "wait"], ["wait", "no"],
        ["i", "mean"], ["or", "rather"],
    ]

    static func hasCorrectionPhrase(_ words: [String]) -> Bool {
        self.correctionPhrases.contains { phrase in
            words.count >= phrase.count &&
                (0 ... words.count - phrase.count).contains { Array(words[$0 ..< $0 + phrase.count]) == phrase }
        }
    }

    /// "Tuesday, no, Wednesday" or "12, sorry, 20": a "no", "sorry" or "wait" set off
    /// by commas after other words. A leading "No," or "Sorry," is not a correction.
    static func hasCommaCueCorrection(_ transcript: String) -> Bool {
        transcript.range(of: #"\w,\s*(no|sorry|wait)[,.]\s*\w"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Negations

    private static let negationWords: Set<String> = [
        "not", "never", "nothing", "nobody", "none", "nowhere", "neither", "nor", "cannot",
    ]

    static func negationCount(_ words: [String]) -> Int {
        words.reduce(0) { count, word in
            count + (self.negationWords.contains(word) || word.hasSuffix("n't") ? 1 : 0)
        }
    }

    // MARK: - Numbers

    private enum NumberKind { case unit, teen, tens, hundred, scale }

    private static let numberWords: [String: (value: Int, kind: NumberKind, isOrdinal: Bool)] = {
        var table: [String: (value: Int, kind: NumberKind, isOrdinal: Bool)] = [:]
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let unitOrdinals = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        for (value, word) in units.enumerated() { table[word] = (value, .unit, false) }
        for (value, word) in unitOrdinals.enumerated() where !word.isEmpty { table[word] = (value, .unit, true) }
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        for (offset, word) in teens.enumerated() {
            table[word] = (10 + offset, .teen, false)
            table[word == "twelve" ? "twelfth" : word + "th"] = (10 + offset, .teen, true)
        }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        for (offset, word) in tens.enumerated() {
            table[word] = ((offset + 2) * 10, .tens, false)
            table[String(word.dropLast()) + "ieth"] = ((offset + 2) * 10, .tens, true)
        }
        table["hundred"] = (100, .hundred, false)
        table["hundredth"] = (100, .hundred, true)
        table["thousand"] = (1000, .scale, false)
        table["thousandth"] = (1000, .scale, true)
        table["million"] = (1_000_000, .scale, false)
        table["billion"] = (1_000_000_000, .scale, false)
        return table
    }()

    private static let scaleZeros = ["hundred": "00", "thousand": "000", "million": "000000", "billion": "000000000"]

    /// Every number in reading order, as one string of digits.
    static func numberDigits(_ words: [String]) -> String {
        var digits = ""
        var run = SpokenNumber()
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.contains(where: { $0.isASCII && $0.isNumber }) {
                digits += run.finish()
                digits += word.filter { $0.isASCII && $0.isNumber }
                // "5 million" reads the same as "five million".
                while index + 1 < words.count, let zeros = self.scaleZeros[words[index + 1]] {
                    digits += zeros
                    index += 1
                }
            } else if let number = self.numberWords[word] {
                run.add(number.value, kind: number.kind)
                if number.isOrdinal { digits += run.finish() }
            } else if word == "and", run.continuesAfterAnd,
                      index + 1 < words.count, self.numberWords[words[index + 1]] != nil
            {
                // "one hundred and five" is one number.
            } else {
                digits += run.finish()
            }
            index += 1
        }
        return digits + run.finish()
    }

    /// Builds spoken numbers word by word. A word that can't extend the number
    /// so far starts a new one, so "nineteen ninety nine" reads 19 then 99.
    private struct SpokenNumber {
        private var total = 0
        private var current = 0
        private var last: NumberKind?
        private var groups = ""

        var continuesAfterAnd: Bool { self.last == .hundred || self.last == .scale }

        mutating func add(_ value: Int, kind: NumberKind) {
            if !self.canFollow(kind) { self.endGroup() }
            switch kind {
            case .unit, .teen, .tens:
                self.current += value
            case .hundred:
                self.current = max(self.current, 1) * 100
            case .scale:
                self.total += max(self.current, 1) * value
                self.current = 0
            }
            self.last = kind
        }

        private func canFollow(_ kind: NumberKind) -> Bool {
            guard let last else { return true }
            switch kind {
            case .unit:
                return last == .tens || (last == .hundred && self.current % 100 == 0) || (last == .scale && self.current == 0)
            case .teen, .tens:
                return (last == .hundred && self.current % 100 == 0) || (last == .scale && self.current == 0)
            case .hundred:
                return last != .hundred && last != .scale && self.current < 100
            case .scale:
                return last != .scale && self.current > 0
            }
        }

        private mutating func endGroup() {
            if self.last != nil { self.groups += String(self.total + self.current) }
            self.total = 0
            self.current = 0
            self.last = nil
        }

        mutating func finish() -> String {
            self.endGroup()
            defer { self.groups = "" }
            return self.groups
        }
    }

    private static func isSubsequence(_ candidate: String, of text: String) -> Bool {
        var remaining = Substring(text)
        for character in candidate {
            guard let found = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: found)...]
        }
        return true
    }
}
