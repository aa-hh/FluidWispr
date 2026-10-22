import Combine
import Foundation

/// Asks the app to open the dictionary audio check, and keeps the last report it showed.
@MainActor
final class DictionaryAudioCheckPresenter: ObservableObject {
    static let shared = DictionaryAudioCheckPresenter()

    @Published var lastReport: DictionaryMatchReport?
    @Published var isRequested = false

    private init() {}
}
