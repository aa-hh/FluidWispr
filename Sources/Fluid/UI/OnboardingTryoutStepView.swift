import SwiftUI

/// The rows of onboarding's "Try it" step. Dictation lands in `finalText` through the
/// onboarding sandbox route (`OnboardingDictationOutputPolicy`); the step's sheet,
/// header and footer belong to `OnboardingFlowView`.
struct OnboardingTryoutStepView: View {
    enum Phase: Equatable {
        case ready
        case changingKey
        case keyConflict(String)
        case waitingForModel
        case listening
        case worked(Date?)
        case nothingHeard
    }

    @Binding var finalText: String

    let language: VoiceEngineLanguage
    let keyHint: (key: String, holds: Bool)
    let phase: Phase
    /// "455 MB of 483 MB" and 0 to 1, shown while the voice model downloads.
    let download: (text: String, fraction: Double)?
    let onToggleShortcut: () -> Void
    let onChangeMicrophone: () -> Void

    private static let languageExamples: [String: [String]] = [
        "ar": [
            "ذكرني أن أرسل الملاحظات قبل الخامسة.",
            "اكتب رسالة قصيرة عن اجتماع اليوم.",
        ],
        "de": [
            "Erinnere mich daran, die Notizen vor fünf zu senden.",
            "Schreib eine kurze Nachricht über das heutige Treffen.",
        ],
        "en": [
            "Remind me to send the notes before five.",
            "Write a short update about today's meeting.",
        ],
        "es": [
            "Recuérdame enviar las notas antes de las cinco.",
            "Escribe una breve actualización sobre la reunión de hoy.",
        ],
        "fr": [
            "Rappelle-moi d'envoyer les notes avant cinq heures.",
            "Écris un court message sur la réunion d'aujourd'hui.",
        ],
        "hi": [
            "मुझे पाँच बजे से पहले नोट्स भेजने की याद दिलाना।",
            "आज की मीटिंग के बारे में एक छोटा अपडेट लिखो।",
        ],
        "it": [
            "Ricordami di inviare gli appunti prima delle cinque.",
            "Scrivi un breve aggiornamento sulla riunione di oggi.",
        ],
        "ja": [
            "5時前にメモを送るようにリマインドして。",
            "今日の会議について短い更新を書いて。",
        ],
        "ko": [
            "다섯 시 전에 메모를 보내라고 알려줘.",
            "오늘 회의에 대한 짧은 업데이트를 써줘.",
        ],
        "nl": [
            "Herinner me eraan om de notities voor vijf uur te sturen.",
            "Schrijf een korte update over de vergadering van vandaag.",
        ],
        "pl": [
            "Przypomnij mi, żeby wysłać notatki przed piątą.",
            "Napisz krótką aktualizację o dzisiejszym spotkaniu.",
        ],
        "pt": [
            "Lembre-me de enviar as notas antes das cinco.",
            "Escreva uma breve atualização sobre a reunião de hoje.",
        ],
        "ru": [
            "Напомни мне отправить заметки до пяти.",
            "Напиши короткое обновление о сегодняшней встрече.",
        ],
        "ta": [
            "ஐந்து மணிக்கு முன் குறிப்புகளை அனுப்ப நினைவூட்டு.",
            "இன்றைய கூட்டத்தைப் பற்றி ஒரு குறுகிய புதுப்பிப்பு எழுது.",
        ],
        "uk": [
            "Нагадай мені надіслати нотатки до п'ятої.",
            "Напиши коротке оновлення про сьогоднішню зустріч.",
        ],
        "vi": [
            "Nhắc tôi gửi ghi chú trước năm giờ.",
            "Viết một cập nhật ngắn về cuộc họp hôm nay.",
        ],
        "zh": [
            "提醒我五点前发送笔记。",
            "写一段关于今天会议的简短更新。",
        ],
    ]

    private var example: String? {
        Self.languageExamples[self.language.id]?.first
    }

    private var isRecordingKey: Bool {
        switch self.phase {
        case .changingKey, .keyConflict: true
        default: false
        }
    }

    private var placeholder: String {
        switch self.phase {
        case .waitingForModel: "You can test as soon as the voice model is ready."
        case .listening: "Listening…"
        default: self.keyHint.holds ? "Hold \(self.keyHint.key) and speak." : "Press \(self.keyHint.key) and speak."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.dictationKeyRow
            if let example = self.example {
                self.row("Say", help: "Or anything you like") {
                    Text(example)
                        .recordText(FWType.transcript)
                        .foregroundStyle(FWColor.textPrimary)
                }
            }
            self.yourWordsRow
            if self.phase == .waitingForModel, let download = self.download {
                self.row("Voice model", help: "Still downloading") {
                    self.status(.waiting, "Almost done")
                    RecordProgressLine(fraction: download.fraction)
                        .frame(width: 400)
                    Text(download.text)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                }
            }
            if self.phase == .listening {
                self.row("Pill", help: "Live") {
                    HStack(spacing: FWMetric.space3) {
                        RecordingPillPreview(state: .listen, size: .medium)
                        Text(self.keyHint.holds ? "Let go of \(self.keyHint.key) when you’re done." : "Press \(self.keyHint.key) again when you’re done.")
                            .recordText(FWType.body)
                            .foregroundStyle(FWColor.textPrimary)
                    }
                }
            }
            if self.phase == .nothingHeard {
                self.row("Pill") {
                    HStack(spacing: FWMetric.space3) {
                        RecordingPillPreview(state: .idle, size: .medium)
                        self.status(.needsYou, "Nothing heard")
                    }
                    self.bodyText("Check that the right microphone is picked, or speak a little closer.", secondary: false)
                    Button("Change microphone", action: self.onChangeMicrophone)
                        .buttonStyle(RecordButtonStyle(kind: .secondary))
                }
            }
        }
    }

    private var dictationKeyRow: some View {
        self.row("Dictation key", help: self.keyHint.holds ? "Hold while you talk, let go to stop" : "Press to start, press again to stop") {
            HStack(spacing: FWMetric.space3) {
                RecordKeycap(
                    key: self.isRecordingKey ? "Press a key" : self.keyHint.key,
                    size: .large,
                    state: self.keycapState
                )
                Button(self.isRecordingKey ? "Cancel" : "Change", action: self.onToggleShortcut)
                    .buttonStyle(RecordButtonStyle(kind: .secondary))
                    .disabled(self.phase == .listening)
            }
            switch self.phase {
            case .changingKey:
                self.bodyText("Press the key or key combination you want. Escape keeps \(self.keyHint.key).", secondary: true)
            case let .keyConflict(message):
                self.status(.needsYou, message)
                self.bodyText("Still listening for a key. Escape keeps \(self.keyHint.key).", secondary: true)
            default:
                if !self.keyHint.holds {
                    self.bodyText("Prefer to hold the key while you talk? Hold to talk, with its own key, is in Settings › Dictation.", secondary: true)
                }
            }
        }
    }

    private var keycapState: RecordKeycap.State {
        switch self.phase {
        case .changingKey: .recording
        case .keyConflict: .conflict
        default: .normal
        }
    }

    private var yourWordsRow: some View {
        RecordLine {
            Text("Your words")
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            if case let .worked(date) = self.phase {
                if let date {
                    Text(date, format: .dateTime.hour().minute())
                        .recordText(FWType.detailStrong)
                        .foregroundStyle(FWColor.textSecondary)
                }
                HStack(spacing: FWMetric.space2) {
                    RecordMark(state: .done)
                    Text("Pasted")
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                }
            }
        } content: {
            RecordField(placeholder: self.placeholder, text: self.$finalText, size: .multi)
                .frame(height: 120)
                .disabled(self.phase == .waitingForModel)
            if case .worked = self.phase {
                HStack(spacing: FWMetric.space2) {
                    RecordMark(state: .done)
                    Text("That’s it. It works the same in every app.")
                        .recordText(FWType.label)
                        .foregroundStyle(FWColor.stateDone)
                }
            }
        }
    }

    private func row(_ name: String, help: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        RecordLine {
            Text(name)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            if let help {
                Text(help)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
        } content: {
            content()
        }
    }

    private func status(_ mark: RecordMark.State, _ text: String) -> some View {
        HStack(spacing: FWMetric.space2) {
            RecordMark(state: mark)
            Text(text)
                .recordText(FWType.label)
                .foregroundStyle(mark == .needsYou ? FWColor.stateAttention : FWColor.textSecondary)
        }
    }

    private func bodyText(_ text: String, secondary: Bool) -> some View {
        Text(text)
            .recordText(FWType.body)
            .foregroundStyle(secondary ? FWColor.textSecondary : FWColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
