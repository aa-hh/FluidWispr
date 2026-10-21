@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PrivateAIHardwareRecommendationTests: XCTestCase {
    private typealias Policy = PrivateAIHardwareRecommendation
    private let gib: UInt64 = 1024 * 1024 * 1024

    // Turns red if a chip, GPU core count or memory size maps to a different local model.
    func testRecommendationForKnownHardware() {
        let cases: [(String, Int?, UInt64, Policy.Model)] = [
            ("Apple M1", 8, 8, .pico), ("Apple M1", 8, 16, .pico),
            ("Apple M1 Pro", 16, 32, .mini), ("Apple M1 Max", 24, 32, .mini),
            ("Apple M2", 10, 24, .pico), ("Apple M2 Pro", 19, 32, .mini),
            ("Apple M2 Max", 30, 32, .mini), ("Apple M3", 10, 24, .pico),
            ("Apple M3 Pro", 18, 36, .mini), ("Apple M3 Max", 30, 36, .mini),
            ("Apple M3 Max", 40, 48, .mini), ("Apple M3 Max", nil, 128, .mini),
            ("Apple M3 Max", 99, 128, .mini), ("Apple M4", 10, 32, .pico),
            ("Apple M4 Pro", 20, 64, .mini), ("Apple M4 Max", 32, 36, .mini),
            ("Apple M4 Max", 40, 128, .mini), ("Apple M5", 10, 32, .pico),
            ("Apple M5 Pro", 20, 64, .mini), ("Apple M5 Max", 32, 36, .mini),
            ("Apple M5 Max", 40, 128, .mini), ("Apple M1 Ultra", 48, 64, .mini),
            ("Apple M2 Ultra", 60, 64, .mini), ("Apple M3 Ultra", 60, 96, .mini),
            ("Apple M5 Max", 40, 8, .pico), ("Apple M5 Max", 40, 16, .mini), ("Apple M5 Max", 40, 24, .mini),
            ("Apple M3 Pro", 18, 18, .mini),
            ("Apple M1 Pro", 16, 16, .mini), ("Apple M2 Pro", 19, 16, .mini),
            ("Apple M4 Pro", 20, 18, .mini), ("Apple M4", 10, 16, .pico),
            ("Intel Core i9", nil, 64, .pico), ("Apple M99 Max", 40, 128, .pico),
            ("", nil, 0, .pico), ("  APPLE   M1 MAX  ", nil, 32, .mini),
        ]
        for (chip, cores, ram, expected) in cases {
            let hardware = Policy.Hardware(chip: chip, memoryBytes: ram * self.gib, gpuCoreCount: cores)
            XCTAssertEqual(Policy.recommend(for: hardware).model, expected, "Unexpected recommendation: \(chip), \(ram) GB")
        }
    }

    // Turns red if the memory boundary or unknown-hardware fallback reports the wrong reason.
    func testBoundaryAndUnknownHardwareReasons() {
        let belowBoundary = Policy.Hardware(chip: "Apple M1 Max", memoryBytes: 16 * self.gib - 1, gpuCoreCount: nil)
        XCTAssertEqual(Policy.recommend(for: belowBoundary).reason, .insufficientMemory)
        let unknown = Policy.Hardware(chip: "unknown", memoryBytes: 128 * self.gib, gpuCoreCount: nil)
        XCTAssertEqual(Policy.recommend(for: unknown).reason, .unknownHardware)
        XCTAssertNil(Policy.recommend(for: unknown).bandwidthGBps)
    }

    // Turns red if repeated callers can see different recommendations for this Mac. The type
    // is main-actor isolated in the app, so these calls do not run in parallel.
    func testConcurrentRequestsShareOneSnapshot() async {
        let hardware = await Policy.currentHardware()
        let expected = Policy.recommend(for: hardware)
        await withTaskGroup(of: Policy.Recommendation.self) { group in
            for _ in 0..<32 {
                group.addTask { await Policy.current() }
            }
            for await result in group {
                XCTAssertEqual(result, expected)
            }
        }
    }
}
