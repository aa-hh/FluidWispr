import SwiftUI

/// The switch for the experimental dictionary matcher ("Learn how you say words").
struct DictionaryMatcherExperimentSettings: View {
    @AppStorage("DictionarySharedFeatureMatcherEnabled") private var enabled = false

    var body: some View {
        RecordSwitch("Learn how you say words", isOn: Binding(
            get: { self.enabled },
            set: { DictionaryMatcherExperiment.setEnabled($0) }
        ))
    }
}
