@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SpeechProviderCacheTests: XCTestCase {
    // Turns red if the cache builds a new provider on every call, which would reload the model.
    func testSameModelReturnsTheCachedProvider() {
        let cache = SpeechProviderCache()
        let first = cache.provider(for: .whisperTiny)
        let second = cache.provider(for: .whisperTiny)
        XCTAssertTrue((first as AnyObject) === (second as AnyObject))
    }

    // Turns red if a model change also drops Nemotron's per-mode providers, or if releaseAll keeps them.
    func testModelChangeKeepsNemotronAndReleaseAllDropsIt() {
        let cache = SpeechProviderCache()
        let whisper = cache.provider(for: .whisperTiny)
        let nemotron = cache.provider(for: .nemotronOffline)

        cache.resetAfterModelChange()
        XCTAssertFalse((cache.provider(for: .whisperTiny) as AnyObject) === (whisper as AnyObject))
        XCTAssertTrue(cache.cachedNemotronProvider(mode: SpeechModel.nemotronOffline.nemotronProviderMode) === (nemotron as AnyObject))

        cache.releaseAll()
        XCTAssertNil(cache.cachedNemotronProvider(mode: SpeechModel.nemotronOffline.nemotronProviderMode))
    }
}
