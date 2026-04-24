import Foundation

// MARK: - Short-input heuristic (word vs dense phrase)

/// Detects *clearly* short task phrases for Option B (LLM title/notes post-processing only).
/// Not language-aware NLP — intentionally lightweight.
enum ShortInputHeuristic {
    /// “Under about 8 word-like units” for space‑separated text: short when under 8 words.
    private static let maxWordCount = 15
    /// CJK / no spaces: one character ≈ one unit; conservative ceiling for a compact line.
    private static let maxCharacterCountDense = 20

    static func isShortTaskPhrase(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }

        let words = t.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }
        if words.count >= 2 {
            return words.count < maxWordCount
        }
        // Single token: typical for CJK or one English word; use length as proxy.
        return t.count < maxCharacterCountDense
    }
}

// MARK: - Option B: LLM presentation only (no second parse)

/// Post-processes **LLM** `ParsedCommand` for short user inputs: keep scheduling/action from
/// the model, preserve any clean backend title, and clear notes for compact phrases.
enum ShortInputLLMPresentation {
    struct Outcome {
        let command: ParsedCommand
        let backendTitle: String
        let rawTranscript: String
        let finalTitle: String
        let isShortInput: Bool
        let didModifyTitle: Bool
        let reason: String
    }

    static func applyOptionB(userInput: String, command: ParsedCommand) -> Outcome {
        let raw = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let backendTitle = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        func outcome(_ c: ParsedCommand, isShort: Bool, reason: String) -> Outcome {
            Outcome(
                command: c,
                backendTitle: backendTitle,
                rawTranscript: raw,
                finalTitle: c.title,
                isShortInput: isShort,
                didModifyTitle: c.title != command.title,
                reason: reason
            )
        }

        guard command.parserSource == .llm else {
            return outcome(command, isShort: false, reason: "nonLLM")
        }
        switch command.actionType {
        case .deleteTask, .rescheduleTask, .appendToTask, .updateTaskTitle:
            return outcome(command, isShort: false, reason: "editActionNoChange")
        default:
            break
        }
        let isShort = ShortInputHeuristic.isShortTaskPhrase(userInput)
        guard isShort else {
            return outcome(command, isShort: false, reason: "notShortInput")
        }

        var c = command
        let titleSource: String
        var reason: String
        if backendTitle.isEmpty {
            titleSource = raw
            reason = "backendTitleEmptyFallbackRaw"
        } else {
            titleSource = backendTitle
            reason = "preserveBackendTitle"
        }

        if command.actionType == .reminder {
            let cleaned = cleanReminderTitle(titleSource)
            if !cleaned.isEmpty, cleaned != titleSource {
                c.title = cleaned
                reason += "+cleanReminderTitle"
            } else if !titleSource.isEmpty {
                c.title = titleSource
            }
        } else if !titleSource.isEmpty {
            c.title = titleSource
        }
        c.notes = nil
        return outcome(c, isShort: true, reason: reason)
    }

    private static func cleanReminderTitle(_ title: String) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，,。.!！?？；;：:"))

        let patterns = [
            #"^(请|麻烦)?(提醒我|提醒一下我|帮我提醒|记得提醒我|记得|叫我)\s*"#,
            #"^(过|在|于)?[一二两三四五六七八九十百千万\d]+(分钟|小时|天|周|星期|个月|年)(后|以后|之后)?\s*"#,
            #"^(明天上午|明天下午|明天晚上|今天|明天|后天|今晚|明早|明晚|上午|下午|晚上|早上|中午|凌晨)?[一二两三四五六七八九十\d]+点(半|[一二三四五六七八九十\d]+分)?\s*"#,
        ]

        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                let next = cleaned.replacingOccurrences(
                    of: pattern,
                    with: "",
                    options: [.regularExpression]
                ).trimmingCharacters(in: punctuation)
                if next != cleaned {
                    cleaned = next
                    changed = true
                }
            }
        }
        return cleaned.trimmingCharacters(in: punctuation)
    }
}
