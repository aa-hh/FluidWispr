import AppKit
import Metal
import MetalKit

/// Draws the rim into an `MTKView`. The view's own display link drives the
/// frames; the controller pauses it while the pill is hidden, so a hidden pill
/// costs nothing.
@MainActor
final class RecordingPillRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Called once per frame, before drawing, for that frame's uniforms.
    var frame: (() -> [Float])?

    /// Nil when this Mac cannot run the shader; the caller then keeps the old overlay.
    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: RecordingPillShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: RecordingPillShader.vertexFunction)
            descriptor.fragmentFunction = library.makeFunction(name: RecordingPillShader.fragmentFunction)
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            DebugLogger.shared.error("Recording pill shader failed to build: \(error.localizedDescription)", source: "RecordingPill")
            return nil
        }
        self.queue = queue
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let size = view.bounds.size
        guard let uniforms = self.frame?(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = self.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        var viewSize = SIMD2<Float>(Float(size.width), Float(size.height))
        encoder.setRenderPipelineState(self.pipeline)
        uniforms.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            encoder.setFragmentBytes(base, length: bytes.count, index: 0)
        }
        encoder.setFragmentBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
