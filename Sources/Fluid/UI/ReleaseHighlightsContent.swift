import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders, settings }
    enum Extra { case pillIllustration, openSettingsButton }

    struct Feature: Identifiable {
        let id: String
        let marginName: String
        let marginDetail: String
        let title: String
        let body: String
        var extra: Extra?
    }

    let release: String
    let title: String
    let subtitle: String
    let features: [Feature]

    static func current(hasPrivateAI _: Bool) -> Self {
        Self(
            release: "1.6.12",
            title: "What’s new in FluidWispr",
            subtitle: "The first FluidWispr release, built from FluidVoice.",
            features: [
                Feature(
                    id: "pill",
                    marginName: "Pill",
                    marginDetail: "While you talk",
                    title: "A pill that follows your voice",
                    body: "Its thin rim brightens as you speak and settles when you pause. When you finish, it folds away smoothly."
                ),
                Feature(
                    id: "paste",
                    marginName: "Paste",
                    marginDetail: "When text can’t land",
                    title: "Nothing lost when a paste fails",
                    body: "If the text can’t go in, a bubble beside the pill holds your words until you paste or copy them. Your clipboard comes back only after the app has read the text.",
                    extra: .pillIllustration
                ),
                Feature(
                    id: "backup",
                    marginName: "Backup",
                    marginDetail: "Every setting",
                    title: "Back up all your settings",
                    body: "Export every setting to one file, then restore it on another Mac or after a reinstall.",
                    extra: .openSettingsButton
                ),
                Feature(
                    id: "typing",
                    marginName: "Typing",
                    marginDetail: "While FluidWispr runs",
                    title: "Typing stays quick",
                    body: "FluidWispr no longer slows down ordinary typing while it watches for your dictation key."
                ),
            ]
        )
    }
}
