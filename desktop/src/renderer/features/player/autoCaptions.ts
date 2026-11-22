// On-device auto captions for the Windows player.
//
// The <video> element is tapped through an AudioWorklet, downsampled to
// 16 kHz mono, and sent in overlapping windows to a Whisper worker. Nothing
// is uploaded: the only network use is the one-time model download, which is
// cached by the browser and can be removed by clearing the app cache.
import type { Cue } from '@/lib/vtt'
import type { CaptionRequest, CaptionResponse } from './captionWorker'
// The worklet ships as source text and runs from a blob URL: Vite would
// otherwise inline a tiny `?url` asset as a data: URL, which the CSP blocks
// and which AudioWorklet cannot load.
import workletSource from './captionWorklet.js?raw'

export type CaptionLanguage = 'en' | 'ja'

export interface GeneratedCaptionChoice {
  language: CaptionLanguage
  translate: boolean
}

export interface GeneratedCaptionState {
  status: 'idle' | 'loading' | 'ready' | 'error'
  detail?: string
  progress?: number
}

const SAMPLE_RATE = 16_000
const WINDOW_SECONDS = 8
const STRIDE_SECONDS = 5
const MAX_CUES = 800

export class AutoCaptionSession {
  private context?: AudioContext
  private worker?: Worker
  private node?: AudioWorkletNode
  private stream?: MediaStream
  private sink?: GainNode
  private chunks: { start: number; data: Float32Array }[] = []
  private buffered = 0
  private lastRun = -Infinity
  private lastPlayhead = -1
  private nextId = 1
  private windows = new Map<number, number>()
  private pending = new Set<number>()
  private cues: Cue[] = []
  private silentChunks = 0
  private disposed = false

  constructor(
    private video: HTMLVideoElement,
    private choice: GeneratedCaptionChoice,
    private onCues: (cues: Cue[]) => void,
    private onState: (state: GeneratedCaptionState) => void
  ) {}

  async start() {
    this.emit({ status: 'loading', detail: 'Preparing on-device captions…' })
    try {
      this.worker = new Worker(new URL('./captionWorker.ts', import.meta.url), { type: 'module' })
      this.worker.onmessage = (event: MessageEvent<CaptionResponse>) => this.receive(event.data)
      this.worker.onerror = event => this.fail(event.message || 'The caption model could not start.')
      this.worker.postMessage({ type: 'load' } satisfies CaptionRequest)

      this.context = new AudioContext()
      const workletUrl = URL.createObjectURL(new Blob([workletSource], { type: 'application/javascript' }))
      try {
        await this.context.audioWorklet.addModule(workletUrl)
      } finally {
        URL.revokeObjectURL(workletUrl)
      }
      this.node = new AudioWorkletNode(this.context, 'caption-tap', {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        channelCount: 1
      })
      this.node.port.onmessage = event => this.append(event.data as Float32Array)
      this.sink = this.context.createGain()
      this.sink.gain.value = 0
      this.node.connect(this.sink).connect(this.context.destination)
      this.attachSource()
      await this.context.resume()
    } catch (error) {
      this.fail(error instanceof Error ? error.message : String(error))
    }
  }

  /** captureStream() leaves playback untouched; the Web Audio fallback is
   *  only used when the element cannot expose a stream (and may be silent
   *  for cross-origin media without CORS headers). */
  private attachSource() {
    const context = this.context!
    let source: AudioNode | undefined
    try {
      const element = this.video as HTMLVideoElement & { captureStream?: () => MediaStream }
      this.stream = element.captureStream?.()
      const track = this.stream?.getAudioTracks()[0]
      if (track) source = context.createMediaStreamSource(new MediaStream([track]))
    } catch {
      source = undefined
    }
    if (!source) {
      const element = context.createMediaElementSource(this.video)
      // The element's own output is routed through the graph now, so keep it
      // audible instead of muting the program.
      this.sink!.gain.value = 1
      source = element
    }
    source.connect(this.node!)
  }

  private append(samples: Float32Array) {
    if (this.disposed) return
    const video = this.video
    if (video.paused || video.ended) return
    const now = video.currentTime
    if (!Number.isFinite(now)) return

    // A seek (or a rate change) invalidates the timeline we buffered.
    if (this.lastPlayhead >= 0 && Math.abs(now - this.lastPlayhead) > 1.5) {
      this.chunks = []
      this.buffered = 0
      this.lastRun = -Infinity
    }
    this.lastPlayhead = now

    let peak = 0
    for (let i = 0; i < samples.length; i += 64) peak = Math.max(peak, Math.abs(samples[i]))
    this.silentChunks = peak < 1e-5 ? this.silentChunks + 1 : 0
    if (this.silentChunks === 12) {
      this.fail('This video does not expose its audio for on-device captions.')
      return
    }

    const seconds = samples.length / SAMPLE_RATE
    this.chunks.push({ start: now - seconds, data: samples })
    this.buffered += seconds
    while (this.chunks.length > 1 && this.buffered > 24) {
      const dropped = this.chunks.shift()!
      this.buffered -= dropped.data.length / SAMPLE_RATE
    }
    this.maybeTranscribe(now)
  }

  private maybeTranscribe(now: number) {
    if (!this.worker) return
    if (this.buffered < WINDOW_SECONDS || now - this.lastRun < STRIDE_SECONDS) return
    // One window in flight keeps the worker from falling behind playback.
    if (this.pending.size >= 1) return
    this.lastRun = now
    const start = now - WINDOW_SECONDS
    const samples = this.collect(start, WINDOW_SECONDS)
    if (!samples) return
    const id = this.nextId++
    this.windows.set(id, start)
    this.pending.add(id)
    this.worker.postMessage({
      type: 'audio',
      id,
      samples,
      language: this.choice.language,
      translate: this.choice.translate
    } satisfies CaptionRequest, [samples.buffer])
  }

  private collect(start: number, length: number): Float32Array | null {
    const total = Math.round(length * SAMPLE_RATE)
    const out = new Float32Array(total)
    const end = start + length
    let filled = 0
    for (const chunk of this.chunks) {
      const chunkStart = chunk.start
      const chunkEnd = chunkStart + chunk.data.length / SAMPLE_RATE
      if (chunkEnd <= start || chunkStart >= end) continue
      const from = Math.max(start, chunkStart)
      const to = Math.min(end, chunkEnd)
      const offset = Math.round((from - start) * SAMPLE_RATE)
      const first = Math.round((from - chunkStart) * SAMPLE_RATE)
      const count = Math.min(Math.round((to - from) * SAMPLE_RATE), total - offset)
      if (count <= 0) continue
      out.set(chunk.data.subarray(first, first + count), offset)
      filled += count
    }
    return filled > total * 0.5 ? out : null
  }

  private receive(message: CaptionResponse) {
    if (this.disposed) return
    switch (message.type) {
      case 'progress':
        this.emit({ status: 'loading', detail: 'Downloading the on-device caption model…', progress: message.loaded / message.total })
        break
      case 'ready':
        this.emit({ status: 'loading', detail: 'Listening for speech…', progress: 1 })
        break
      case 'result': {
        this.pending.delete(message.id)
        const start = this.windows.get(message.id) ?? 0
        this.windows.delete(message.id)
        const end = start + WINDOW_SECONDS
        const fresh: Cue[] = message.chunks.map(chunk => ({
          start: start + chunk.start,
          end: Math.max(start + chunk.end, start + chunk.start + 0.8),
          text: chunk.text
        }))
        this.cues = this.cues.filter(cue => cue.end <= start + 0.25 || cue.start >= end - 0.25).concat(fresh)
        this.cues.sort((a, b) => a.start - b.start)
        if (this.cues.length > MAX_CUES) this.cues = this.cues.slice(-MAX_CUES)
        this.onCues(this.cues)
        this.emit({ status: 'ready' })
        break
      }
      case 'error':
        this.fail(message.message)
        break
    }
  }

  private emit(state: GeneratedCaptionState) {
    if (!this.disposed) this.onState(state)
  }

  private fail(detail: string) {
    if (this.disposed) return
    this.onState({ status: 'error', detail })
  }

  dispose() {
    if (this.disposed) return
    this.disposed = true
    this.stream?.getTracks().forEach(track => track.stop())
    this.node?.port.close()
    this.node?.disconnect()
    this.sink?.disconnect()
    this.context?.close().catch(() => {})
    this.worker?.terminate()
    this.chunks = []
    this.cues = []
    this.windows.clear()
    this.pending.clear()
  }
}
