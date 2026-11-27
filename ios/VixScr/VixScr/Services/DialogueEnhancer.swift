import Accelerate
import Foundation

/// Makes the caption engine's copy of the sound easier to understand. You
/// never hear this; the player plays the original.
///
/// 1. Dialogue extraction: films and TV mix speech dead centre, equal in
///    both channels, while music and effects are usually wide. For each
///    frequency, the more alike the two channels are, the more of it is
///    kept; what differs between them is turned down.
/// 2. Speech EQ: rumble and bass below ~120 Hz and hiss above ~8 kHz go,
///    and 1–4 kHz (where consonants are) gets a gentle +4 dB.
/// 3. Level evening: quiet lines come up, loud bangs come down.
///
/// Runs as a stream (2048-point STFT, 75 % overlap), so chunk edges never
/// click. Output sample i lines up with input sample i; the last 1536
/// samples of a chunk come out with the next one.
final class DialogueEnhancer {
    private static let size = 2048
    private static let hop = 512
    private static let log2n = vDSP_Length(11)

    private let setup: FFTSetup?
    private var window = [Float](repeating: 0, count: DialogueEnhancer.size)

    private var rate: Double = 0
    private var weights: [Float] = []
    private var smoothedGain = [Float](repeating: 1, count: DialogueEnhancer.size / 2)
    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []
    private var accumulator = [Float](repeating: 0, count: DialogueEnhancer.size)
    /// Time of the next output sample, and where the next input should start.
    private var outputTime: Double?
    private var expectedInput: Double?

    // Level evening.
    private var envelope: Float = 0
    private var levelGain: Float = 1

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        var hann = [Float](repeating: 0, count: Self.size)
        vDSP_hann_window(&hann, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        window = hann
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func reset() {
        pendingLeft = []
        pendingRight = []
        accumulator = [Float](repeating: 0, count: Self.size)
        smoothedGain = [Float](repeating: 1, count: Self.size / 2)
        outputTime = nil
        expectedInput = nil
        envelope = 0
        levelGain = 1
    }

    /// The enhanced sound for `chunk`, or nil until enough has arrived.
    func process(_ chunk: AudioChunk) -> AudioChunk? {
        guard chunk.rate > 0, !chunk.samples.isEmpty, setup != nil else { return chunk }
        if chunk.rate != rate { rate = chunk.rate; weights = Self.eqWeights(rate: rate); reset() }
        if let expected = expectedInput, abs(expected - chunk.start) > 0.05 { reset() }
        if outputTime == nil { outputTime = chunk.start }
        expectedInput = chunk.end

        // Mono sound counts as perfectly centred: only EQ and levelling apply.
        pendingLeft.append(contentsOf: chunk.stereo?.left ?? chunk.samples)
        pendingRight.append(contentsOf: chunk.stereo?.right ?? chunk.samples)

        var output: [Float] = []
        output.reserveCapacity(pendingLeft.count)
        while pendingLeft.count >= Self.size {
            processFrame(into: &output)
            pendingLeft.removeFirst(Self.hop)
            pendingRight.removeFirst(Self.hop)
        }
        guard !output.isEmpty, let start = outputTime else { return nil }
        level(&output)
        outputTime = start + Double(output.count) / rate
        return AudioChunk(start: start, rate: rate, samples: output, playlistEnd: chunk.playlistEnd)
    }

    // MARK: STFT

    private func processFrame(into output: inout [Float]) {
        guard let setup else { return }
        let n = Self.size
        let half = n / 2
        var leftReal = [Float](repeating: 0, count: half), leftImag = [Float](repeating: 0, count: half)
        var rightReal = [Float](repeating: 0, count: half), rightImag = [Float](repeating: 0, count: half)
        forward(Array(pendingLeft[0..<n]), real: &leftReal, imag: &leftImag, setup: setup)
        forward(Array(pendingRight[0..<n]), real: &rightReal, imag: &rightImag, setup: setup)

        var midReal = [Float](repeating: 0, count: half), midImag = [Float](repeating: 0, count: half)
        // Bin 0 packs DC (real) and Nyquist (imag): EQ removes both.
        for k in 1..<half {
            let lr = leftReal[k], li = leftImag[k], rr = rightReal[k], ri = rightImag[k]
            let energy = lr * lr + li * li + rr * rr + ri * ri
            // 1 when both channels carry the same thing (centre), 0 when
            // they're unrelated or opposite (wide music and effects).
            let likeness = energy > 1e-12 ? max(0, 2 * (lr * rr + li * ri) / energy) : 1
            let target: Float = 0.1 + 0.9 * likeness * likeness
            // Smoothed over time so the result doesn't warble.
            smoothedGain[k] = 0.65 * smoothedGain[k] + 0.35 * target
            let gain = 0.5 * smoothedGain[k] * weights[k]
            midReal[k] = (lr + rr) * gain
            midImag[k] = (li + ri) * gain
        }

        var frame = [Float](repeating: 0, count: n)
        inverse(real: &midReal, imag: &midImag, into: &frame, setup: setup)
        // Hann analysis + synthesis at 75 % overlap sums to 1.5; the real
        // FFT round trip scales by 2n.
        let scale = 1 / (1.5 * Float(2 * n))
        for i in 0..<n { accumulator[i] += frame[i] * window[i] * scale }
        output.append(contentsOf: accumulator[0..<Self.hop])
        accumulator.removeFirst(Self.hop)
        accumulator.append(contentsOf: [Float](repeating: 0, count: Self.hop))
    }

    private func forward(_ samples: [Float], real: inout [Float], imag: inout [Float], setup: FFTSetup) {
        let n = Self.size
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    private func inverse(real: inout [Float], imag: inout [Float], into frame: inout [Float], setup: FFTSetup) {
        let n = Self.size
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_INVERSE))
                frame.withUnsafeMutableBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2))
                    }
                }
            }
        }
    }

    /// Per-bin EQ: high-pass at ~120 Hz, low-pass at ~8 kHz, +4 dB around
    /// 2.5 kHz.
    private static func eqWeights(rate: Double) -> [Float] {
        let half = size / 2
        return (0..<half).map { k in
            let f = Double(k) * rate / Double(size)
            var w = min(1, max(0, (f - 80) / 70))
            if f > 7_500 { w *= max(0, 1 - (f - 7_500) / 1_500) }
            let octaves = log2(max(f, 1) / 2_500)
            w *= 1 + 0.6 * exp(-(octaves * octaves) / (2 * 0.8 * 0.8))
            return Float(w)
        }
    }

    // MARK: Level

    /// Brings the level towards -20 dBFS: fast to turn loud bits down,
    /// slow to bring quiet ones up, never more than +18 dB, and silence
    /// isn't pumped up into noise.
    private func level(_ samples: inout [Float]) {
        let attack = Float(1 - exp(-1 / (0.01 * rate)))
        let release = Float(1 - exp(-1 / (0.4 * rate)))
        let follow = Float(1 - exp(-1 / (0.05 * rate)))
        let target: Float = 0.1
        for i in samples.indices {
            let power = samples[i] * samples[i]
            envelope += (power > envelope ? attack : release) * (power - envelope)
            let rms = envelope.squareRoot()
            let wanted: Float = rms < 0.001 ? 1 : min(8, max(0.3, target / rms))
            levelGain += follow * (wanted - levelGain)
            var y = samples[i] * levelGain
            // Soft ceiling instead of hard clipping.
            if abs(y) > 0.9 { y = (y > 0 ? 1 : -1) * (0.9 + 0.1 * tanh((abs(y) - 0.9) * 10)) }
            samples[i] = y
        }
    }
}
