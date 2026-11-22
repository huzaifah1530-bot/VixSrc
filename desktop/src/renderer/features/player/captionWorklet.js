// AudioWorklet that taps the playing video and hands the main thread 16 kHz
// mono PCM. Keeping the downsample here means no per-frame work in React.
class CaptionTap extends AudioWorkletProcessor {
  constructor() {
    super()
    this.ratio = sampleRate / 16000
    this.sum = 0
    this.count = 0
    this.chunk = new Float32Array(8192)
    this.length = 0
  }

  process(inputs) {
    const input = inputs[0]
    if (!input || input.length === 0) return true
    const frames = input[0].length
    const channels = input.length
    for (let i = 0; i < frames; i++) {
      let sample = 0
      for (let c = 0; c < channels; c++) sample += input[c][i]
      this.sum += sample / channels
      this.count++
      if (this.count >= this.ratio) {
        this.chunk[this.length++] = this.sum / this.count
        this.sum = 0
        this.count = 0
        if (this.length === this.chunk.length) {
          this.port.postMessage(this.chunk, [this.chunk.buffer])
          this.chunk = new Float32Array(8192)
          this.length = 0
        }
      }
    }
    return true
  }
}

registerProcessor('caption-tap', CaptionTap)
