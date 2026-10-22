import SwiftUI

/// The Changelog window: release notes from GitHub as ruled lines, one per release.
struct ChangelogView: View {
    @State private var releases: [SimpleUpdater.ReleaseNote] = []
    @State private var isRefreshing = false
    @State private var loadFailed = false
    @State private var lastChecked: Date?

    private let releaseLimit = 3

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        RecordHeader("Changelog", subtitle: self.subtitleText(now: context.date)) { self.refreshButton }
                    }
                    if self.releases.isEmpty, self.isRefreshing {
                        self.loadingLine
                        self.fillerLine(showsButton: false)
                    } else if self.releases.isEmpty {
                        self.failedLine
                        self.fillerLine(showsButton: false)
                    } else {
                        ForEach(Array(self.releases.enumerated()), id: \.element) { index, release in
                            ChangelogReleaseLine(
                                release: release,
                                isLatest: index == 0,
                                showsNotLoaded: index == 0 && self.loadFailed
                            )
                        }
                        self.fillerLine(showsButton: true)
                    }
                }
                .padding(.top, FWMetric.space8)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .background(FWColor.surfaceWindow.ignoresSafeArea())
        .task {
            self.loadCachedReleases()
            await self.refreshReleases()
        }
    }

    private func subtitleText(now: Date) -> String {
        guard !self.releases.isEmpty, !self.loadFailed, let lastChecked else { return "Release notes from GitHub." }
        let seconds = now.timeIntervalSince(lastChecked)
        guard seconds >= 60 else { return "Release notes from GitHub. Checked just now." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Release notes from GitHub. Checked \(formatter.localizedString(for: lastChecked, relativeTo: now))."
    }

    private var refreshButton: some View {
        HStack(spacing: FWMetric.space3) {
            if self.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            }
            Button("Refresh") {
                Task { await self.refreshReleases() }
            }
            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
            .disabled(self.isRefreshing)
        }
    }

    private var loadingLine: some View {
        RecordLine {
            EmptyView()
        } content: {
            HStack(spacing: FWMetric.space3) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                Text("Loading release notes…")
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
            }
        }
    }

    private var failedLine: some View {
        RecordLine {
            ChangelogNotLoadedNote()
        } content: {
            Text("Couldn’t load release notes")
                .recordText(FWType.section)
                .foregroundStyle(FWColor.textPrimary)
            Text("FluidWispr couldn’t reach GitHub. Check your connection, then try again.")
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: FWMetric.space3) {
                Button("Try again") {
                    Task { await self.refreshReleases() }
                }
                .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                if let url = SimpleUpdater.releasesPageURL {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                }
            }
            .padding(.top, FWMetric.space3)
        }
    }

    /// The last line: no bottom rule, and it runs down to the bottom of the window.
    private func fillerLine(showsButton: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: FWMetric.sizeMargin)
            RecordMarginRule()
            Group {
                if showsButton, let url = SimpleUpdater.releasesPageURL {
                    Button("Older release notes on GitHub") { NSWorkspace.shared.open(url) }
                        .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                }
            }
            .padding(EdgeInsets(top: 14, leading: FWMetric.space6, bottom: 14, trailing: FWMetric.space8))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    private func loadCachedReleases() {
        let cacheKey = self.cacheKey
        guard
            let data = UserDefaults.standard.data(forKey: cacheKey),
            let cache = try? JSONDecoder().decode(ChangelogCache.self, from: data)
        else { return }

        self.releases = Array(cache.releases.prefix(self.releaseLimit))
    }

    private func refreshReleases() async {
        guard !self.isRefreshing else { return }

        self.isRefreshing = true

        do {
            let includePrerelease = SettingsStore.shared.betaReleasesEnabled
            let fetched = try await SimpleUpdater.shared.fetchRecentReleaseNotes(
                limit: self.releaseLimit,
                includePrerelease: includePrerelease
            )
            let limitedReleases = Array(fetched.prefix(self.releaseLimit))
            self.releases = limitedReleases
            self.saveCachedReleases(limitedReleases)
            self.loadFailed = false
        } catch {
            DebugLogger.shared.debug("Changelog refresh failed: \(error.localizedDescription)", source: "ChangelogView")
            self.loadFailed = true
        }

        self.lastChecked = Date()
        self.isRefreshing = false
    }

    private func saveCachedReleases(_ releases: [SimpleUpdater.ReleaseNote]) {
        let cache = ChangelogCache(releases: releases, savedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: self.cacheKey)
    }

    private var cacheKey: String {
        let channel = SettingsStore.shared.betaReleasesEnabled ? "beta" : "stable"
        return "FluidVoiceChangelogCache.\(channel)"
    }
}

private struct ChangelogCache: Codable {
    let releases: [SimpleUpdater.ReleaseNote]
    let savedAt: Date
}

private struct ChangelogNotLoadedNote: View {
    var body: some View {
        Text("Not loaded")
            .recordText(FWType.detailStrong)
            .foregroundStyle(FWColor.stateAttention)
    }
}

private struct ChangelogReleaseLine: View {
    let release: SimpleUpdater.ReleaseNote
    let isLatest: Bool
    let showsNotLoaded: Bool

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    var body: some View {
        RecordLine {
            if self.showsNotLoaded {
                ChangelogNotLoadedNote()
            }
            Text(self.release.version)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            if let publishedAt = self.release.publishedAt {
                Text(Self.dateFormat.string(from: publishedAt))
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
            if let tag = self.tag {
                Text(tag)
                    .recordText(FWType.smallStrong)
                    .foregroundStyle(FWColor.textTertiary)
            }
        } content: {
            Text(self.release.title)
                .recordText(FWType.section)
                .foregroundStyle(FWColor.textPrimary)
            ForEach(self.noteBlocks, id: \.self) { block in
                ChangelogNoteBlock(block: block)
            }
        }
    }

    private var tag: String? {
        if self.release.isPrerelease { return "Beta" }
        return self.isLatest ? "Latest" : nil
    }

    private var noteBlocks: [ChangelogNoteBlock.Model] {
        ChangelogNoteBlock.Model.make(
            from: self.release.notes,
            releaseTitle: self.release.title,
            version: self.release.version
        )
    }
}

private struct ChangelogNoteBlock: View {
    enum Kind: Hashable {
        case heading
        case bullet
        case paragraph
    }

    struct Model: Hashable {
        let kind: Kind
        let text: String

        static func make(from notes: String, releaseTitle: String, version: String) -> [Model] {
            var blocks: [Model] = []

            for rawLine in notes.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }

                if line.hasPrefix("#") {
                    let heading = String(line.drop { $0 == "#" })
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !self.shouldStop(atHeading: heading) else { break }
                    guard heading != releaseTitle, heading != version else { continue }

                    blocks.append(Model(kind: .heading, text: heading))
                    continue
                }

                guard !self.isBoilerplateLine(line) else { continue }

                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    blocks.append(Model(kind: .bullet, text: String(line.dropFirst(2))))
                    continue
                }

                blocks.append(Model(kind: .paragraph, text: line))
            }

            return blocks
        }

        private static func shouldStop(atHeading heading: String) -> Bool {
            heading.localizedCaseInsensitiveContains("contributors") ||
                heading.localizedCaseInsensitiveContains("need help")
        }

        private static func isBoilerplateLine(_ line: String) -> Bool {
            let lowercased = line.lowercased()
            return lowercased.contains("report issues:") ||
                lowercased.contains("github.com/altic-dev/fluidvoice/issues") ||
                lowercased.contains("github.com/altic-dev/fluid-oss/issues")
        }
    }

    let block: Model

    var body: some View {
        switch self.block.kind {
        case .heading:
            Text(self.block.text)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
                .padding(.top, 2)
        case .bullet:
            HStack(alignment: .top, spacing: FWMetric.space3) {
                Circle()
                    .fill(FWColor.textTertiary)
                    .frame(width: 4, height: 4)
                    .frame(width: 4, height: 18)
                Text(self.markdownAttributedString(from: self.block.text))
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph:
            Text(self.markdownAttributedString(from: self.block.text))
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(text)
        }
    }
}

#Preview {
    ChangelogView()
        .frame(width: 720, height: 600)
}
