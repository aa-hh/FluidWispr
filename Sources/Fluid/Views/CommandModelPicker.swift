import SwiftUI

struct CommandModelPicker: View {
    let options: [CommandModelOption]
    let selectedProviderID: String
    let selectedModelID: String
    let onSelect: (CommandModelOption) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var highlightedID: String?
    @State private var keyboardScrollID: String?

    private enum RowIdentity: Hashable {
        case provider(String)
        case model(String)
    }

    private enum PickerRow: Identifiable {
        case provider(id: String, name: String)
        case model(CommandModelOption)

        var id: RowIdentity {
            switch self {
            case let .provider(id, _): .provider(id)
            case let .model(option): .model(option.id)
            }
        }
    }

    private var filteredOptions: [CommandModelOption] {
        CommandModelCatalog.filtered(self.options, query: self.searchText)
    }

    private var selectedOptionID: String? {
        self.options.first {
            $0.providerID == self.selectedProviderID && $0.modelID == self.selectedModelID
        }?.id
    }

    var body: some View {
        let filtered = self.filteredOptions
        let rows = self.pickerRows(for: filtered)
        VStack(spacing: 0) {
            self.searchField
            Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
            if self.options.isEmpty {
                self.emptyState(
                    title: "No models available",
                    message: "Verify a chat provider in Advanced cleanup to make its models available here."
                )
            } else if filtered.isEmpty {
                self.emptyState(
                    title: "No matching models",
                    message: "Try a model name, model ID, or provider name."
                )
            } else {
                self.modelList(rows: rows, modelCount: filtered.count)
            }
        }
        .frame(width: 350)
        .foregroundStyle(FWColor.textPrimary)
        .background(FWColor.surfaceRaised)
        .onAppear {
            self.resetHighlight(preferSelected: true)
        }
        .onChange(of: self.searchText) { _, _ in self.resetHighlight(preferSelected: false) }
        .onChange(of: self.options) { _, _ in
            if !self.filteredOptions.contains(where: { $0.id == self.highlightedID }) {
                self.resetHighlight(preferSelected: true)
            }
        }
        .onChange(of: self.selectedOptionID) { _, _ in self.resetHighlight(preferSelected: true) }
        .onMoveCommand { direction in
            if direction == .up { self.moveHighlight(by: -1) }
            if direction == .down { self.moveHighlight(by: 1) }
        }
        .onExitCommand(perform: self.onDismiss)
    }

    private var searchField: some View {
        RecordField(placeholder: "Search all models", text: self.$searchText)
            .accessibilityLabel("Search models from all verified providers")
            .onSubmit(self.selectHighlighted)
            .onKeyPress(.upArrow) {
                self.moveHighlight(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                self.moveHighlight(by: 1)
                return .handled
            }
            .padding(FWMetric.space3)
    }

    private func modelList(rows: [PickerRow], modelCount: Int) -> some View {
        let selectedID = self.selectedOptionID
        let highlightedID = self.highlightedID
        let headingCount = rows.count - modelCount
        let height = min(340, max(96, CGFloat(modelCount) * 44 + CGFloat(headingCount) * 28 + 12))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case let .provider(_, name):
                            Text(name)
                                .recordText(FWType.detailStrong)
                                .foregroundStyle(FWColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: FWMetric.space3, leading: FWMetric.space4, bottom: FWMetric.space2, trailing: FWMetric.space4))
                                .accessibilityAddTraits(.isHeader)
                        case let .model(option):
                            ModelRow(
                                option: option,
                                selected: option.id == selectedID,
                                highlighted: option.id == highlightedID,
                                onSelect: { self.onSelect(option) },
                                onHighlight: { self.highlightedID = option.id }
                            )
                        }
                    }
                }
                .padding(FWMetric.space2)
            }
            .frame(height: height)
            .onChange(of: self.keyboardScrollID) { _, id in
                guard let id else { return }
                proxy.scrollTo(RowIdentity.model(id), anchor: .center)
            }
            .onAppear {
                if let highlightedID { proxy.scrollTo(RowIdentity.model(highlightedID), anchor: .center) }
            }
        }
    }

    private struct ModelRow: View {
        let option: CommandModelOption
        let selected: Bool
        let highlighted: Bool
        let onSelect: () -> Void
        let onHighlight: () -> Void

        @FocusState private var focused: Bool

        var body: some View {
            Button(action: self.onSelect) {
                HStack(spacing: FWMetric.space3) {
                    VStack(alignment: .leading, spacing: FWMetric.space1) {
                        Text(self.option.displayName)
                            .recordText(FWType.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if self.option.modelID != self.option.displayName {
                            Text(self.option.modelID)
                                .recordText(FWType.small)
                                .foregroundStyle(FWColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                        .foregroundStyle(FWColor.textPrimary)
                        .opacity(self.selected ? 1 : 0)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: FWMetric.sizeRowMin - 2 * FWMetric.space2)
                .padding(.horizontal, FWMetric.space4)
                .padding(.vertical, FWMetric.space2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused(self.$focused)
            .focusEffectDisabled()
            .background(
                self.highlighted ? FWColor.surfaceSelected : .clear,
                in: RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous)
            )
            .accessibilityLabel("\(self.option.displayName), \(self.option.providerName)")
            .accessibilityAddTraits(self.selected ? .isSelected : [])
            .help("\(self.option.providerName) · \(self.option.modelID)")
            .onHover { hovering in
                if hovering { self.onHighlight() }
            }
            .onChange(of: self.focused) { _, focused in
                if focused { self.onHighlight() }
            }
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space2) {
            Text(title)
                .recordText(FWType.label)
            Text(message)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: FWMetric.space4, leading: FWMetric.space4, bottom: FWMetric.space5, trailing: FWMetric.space4))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerRows(for options: [CommandModelOption]) -> [PickerRow] {
        var providerOrder: [String] = []
        var groups: [String: [CommandModelOption]] = [:]
        for option in options {
            if groups[option.providerID] == nil { providerOrder.append(option.providerID) }
            groups[option.providerID, default: []].append(option)
        }
        return providerOrder.flatMap { providerID in
            guard let models = groups[providerID], let first = models.first else { return [PickerRow]() }
            return [.provider(id: providerID, name: first.providerName)] + models.map(PickerRow.model)
        }
    }

    private func resetHighlight(preferSelected: Bool) {
        let filtered = self.filteredOptions
        if preferSelected, let selectedID = self.selectedOptionID, filtered.contains(where: { $0.id == selectedID }) {
            self.highlightedID = selectedID
        } else {
            self.highlightedID = filtered.first?.id
        }
        self.keyboardScrollID = self.highlightedID
    }

    private func moveHighlight(by offset: Int) {
        let filtered = self.filteredOptions
        guard !filtered.isEmpty else { return }
        let index: Int
        if let current = filtered.firstIndex(where: { $0.id == self.highlightedID }) {
            index = min(filtered.count - 1, max(0, current + offset))
        } else {
            index = offset > 0 ? 0 : filtered.count - 1
        }
        self.highlightedID = filtered[index].id
        self.keyboardScrollID = self.highlightedID
    }

    private func selectHighlighted() {
        guard let option = self.filteredOptions.first(where: { $0.id == self.highlightedID }) else { return }
        self.onSelect(option)
    }
}
