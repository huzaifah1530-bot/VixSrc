import Accelerate
import CoreVideo
import Foundation

/// Turns a decoded video frame into a `VisualSample`.
///
/// The frame's brightness is averaged over a 9 × 8 grid (inside a small
/// margin, so channel logos and letterbox edges matter less) and each cell
/// is compared with its right-hand neighbour: 64 bits that survive
/// re-encoding, resolution changes and small colour shifts, so the same
/// opening in two episodes hashes nearly the same.
enum FrameHasher {
    private static let columns = 9
    private static let rows = 8
    /// Sample points per cell side.
    private static let samplesPerCell = 8

    static func sample(_ buffer: CVPixelBuffer, time: Double) -> VisualSample? {
        guard time.isFinite else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width: Int, height: Int, rowBytes: Int
        let base: UnsafeRawPointer
        let isBGRA: Bool
        if CVPixelBufferIsPlanar(buffer) {
            guard let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            base = UnsafeRawPointer(plane)
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            isBGRA = false
        } else if format == kCVPixelFormatType_32BGRA {
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            base = UnsafeRawPointer(address)
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            isBGRA = true
        } else {
            return nil
        }
        guard width >= 32, height >= 32 else { return nil }

        let x0 = Double(width) * 0.06, x1 = Double(width) * 0.94
        let y0 = Double(height) * 0.08, y1 = Double(height) * 0.92
        let cellW = (x1 - x0) / Double(columns)
        let cellH = (y1 - y0) / Double(rows)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var cells = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0
                for sy in 0..<samplesPerCell {
                    let y = Int(y0 + (Double(row) + (Double(sy) + 0.5) / Double(samplesPerCell)) * cellH)
                    let line = bytes + min(height - 1, y) * rowBytes
                    for sx in 0..<samplesPerCell {
                        let x = min(width - 1, Int(x0 + (Double(column) + (Double(sx) + 0.5) / Double(samplesPerCell)) * cellW))
                        if isBGRA {
                            let p = line + x * 4
                            sum += (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
                        } else {
                            sum += Int(line[x])
                        }
                    }
                }
                cells[row * columns + column] = Double(sum) / Double(samplesPerCell * samplesPerCell)
            }
        }

        var hash: UInt64 = 0
        var strongEdges = 0
        for row in 0..<rows {
            for column in 0..<(columns - 1) {
                let left = cells[row * columns + column]
                let right = cells[row * columns + column + 1]
                if left < right { hash |= 1 << UInt64(row * (columns - 1) + column) }
                if abs(left - right) > 3 { strongEdges += 1 }
            }
        }
        let mean = cells.reduce(0, +) / Double(cells.count)
        let variance = cells.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(cells.count)
        // Flat or nearly flat frames: their bits are noise.
        let informative = variance.squareRoot() >= 7 && strongEdges >= 18
        return VisualSample(time: time, hash: hash, informative: informative)
    }
}

/// Audio sub-fingerprints in the style of Haitsma & Kalker: the sound is
/// brought down to 8 kHz mono, analysed in 256 ms windows every 32 ms, and
/// each window yields 32 bits saying whether the energy difference between
/// neighbouring bands (300–2000 Hz, log-spaced) grew or shrank since the
/// previous window. Loudness doesn't change the bits, and the same music
/// gives nearly the same bits in every episode.
final class AudioFingerprinter {
    static let sampleRate = 8000.0
    static let frameLength = 2048
    static let hopLength = 256
    static var hop: Double { Double(hopLength) / sampleRate }
    private static let log2n = vDSP_Length(11)
    private static let bandCount = 33

    private let setup: FFTSetup?
    private var window = [Float](repeating: 0, count: AudioFingerprinter.frameLength)
    private let bandEdges: [Int]

    private var ring = [Float](repeating: 0, count: AudioFingerprinter.frameLength)
    private var ringIndex = 0
    private var filled = 0
    private var sinceCode = 0
    /// Down-sampled samples produced since `baseTime`.
    private var produced = 0
    private var baseTime: Double?
    private var expectedNextInputTime: Double?
    private var accumulator: Float = 0
    private var accumulated = 0
    private var phase = 0.0
    private var previousBands: [Float]?

    private var frame = [Float](repeating: 0, count: AudioFingerprinter.frameLength)
    private var real = [Float](repeating: 0, count: AudioFingerprinter.frameLength / 2)
    private var imaginary = [Float](repeating: 0, count: AudioFingerprinter.frameLength / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioFingerprinter.frameLength / 2)

    init() {
        let binHz = Self.sampleRate / Double(Self.frameLength)
        var edges: [Int] = []
        for i in 0...Self.bandCount {
            let f = 300 * pow(2000.0 / 300.0, Double(i) / Double(Self.bandCount))
            var bin = Int((f / binHz).rounded())
            if let last = edges.last, bin <= last { bin = last + 1 }
            edges.append(bin)
        }
        bandEdges = edges
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        var hann = [Float](repeating: 0, count: Self.frameLength)
        vDSP_hann_window(&hann, vDSP_Length(Self.frameLength), Int32(vDSP_HANN_NORM))
        window = hann
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// Forget everything; the next samples start a new run.
    func reset() {
        ringIndex = 0
        filled = 0
        sinceCode = 0
        produced = 0
        baseTime = nil
        expectedNextInputTime = nil
        accumulator = 0
        accumulated = 0
        phase = 0
        previousBands = nil
    }

    /// Feeds mono samples starting at `startTime` (player timeline). A gap
    /// or overlap of more than 80 ms starts a new run.
    func append(_ samples: [Float], startTime: Double, inputRate: Double) -> [AudioCode] {
        guard !samples.isEmpty, inputRate > 0, startTime.isFinite else { return [] }
        if let expected = expectedNextInputTime, abs(expected - startTime) > 0.08 { reset() }
        if baseTime == nil { baseTime = startTime }
        expectedNextInputTime = startTime + Double(samples.count) / inputRate

        let factor = inputRate / Self.sampleRate
        var codes: [AudioCode] = []
        for sample in samples {
            accumulator += sample
            accumulated += 1
            phase += 1
            guard phase >= factor else { continue }
            phase -= factor
            push(accumulator / Float(accumulated), into: &codes)
            accumulator = 0
            accumulated = 0
        }
        return codes
    }

    private func push(_ value: Float, into codes: inout [AudioCode]) {
        ring[ringIndex] = value
        ringIndex = (ringIndex + 1) % Self.frameLength
        filled = min(Self.frameLength, filled + 1)
        produced += 1
        sinceCode += 1
        guard filled == Self.frameLength, sinceCode >= Self.hopLength, let baseTime else { return }
        sinceCode = 0
        let bands = analyse()
        defer { previousBands = bands }
        guard let previous = previousBands else { return }
        let total = bands.reduce(0, +)
        var code: UInt32 = 0
        if total > 1e-9 {
            for b in 0..<(Self.bandCount - 1) {
                let now = bands[b] - bands[b + 1]
                let before = previous[b] - previous[b + 1]
                if now - before > 0 { code |= 1 << UInt32(b) }
            }
        }
        // Centre of the analysed window.
        let time = baseTime + (Double(produced) - Double(Self.frameLength) / 2) / Self.sampleRate
        codes.append(AudioCode(time: time, code: code))
    }

    private func analyse() -> [Float] {
        guard let setup else { return [Float](repeating: 0, count: Self.bandCount) }
        let n = Self.frameLength
        // Oldest sample first.
        for i in 0..<n { frame[i] = ring[(ringIndex + i) % n] * window[i] }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                frame.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { output in
                    vDSP_zvmags(&split, 1, output.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = min(bandEdges[b], n / 2 - 1)
            let hi = min(max(bandEdges[b + 1], lo + 1), n / 2)
            var sum: Float = 0
            for k in lo..<hi { sum += magnitudes[k] }
            bands[b] = sum
        }
        return bands
    }
}
