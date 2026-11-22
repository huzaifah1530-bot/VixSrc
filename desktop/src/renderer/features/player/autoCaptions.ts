// On-device auto captions for the Windows player.
//
// Whisper needs a few seconds of audio and a few more to decode it, so
// captions built from the audio that is *currently playing* always arrive
// after the words were spoken. To get ahead of the picture, a second hidden
// <video> plays the same stream a little in front of the visible one. Its
// audio goes through an AudioWorklet (muted at the output), is downsampled to
// 16 kHz mono, and is sent in contiguous windows to a Whisper worker. Cues are
// stamped in media time, so they are ready before the visible playhead
// reaches them.
//
// Nothing is uploaded. The only network use besides the second playback of
// the stream is the one-time model download, cached by the browser.
import Hls from 'hls.js'
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

export interface CaptionMedia {
  url: string
  hls: boolean
}

export interface GeneratedCaptionState {
  status: 'idle' | 'loading' | 'ready' | 'error'
  detail?: string
  progress?: number
}

const SAMPLE_RATE = 16_000
/** Audio sent to Whisper per request. */
const WINDOW_SECONDS = 10
/** The last seconds of a window may cut a word in half, so they are redone by the next window. */
const TAIL_SECONDS = 2.5
/** Advance used when a window has no complete segment (silence, or one very long utterance). */
const STRIDE_SECONDS = 6
/** How far the hidden player runs in front of the visible one. */
const LEAD_SECONDS = 24
/** If the lead falls below this (seek, stall) the hidden player jumps back to LEAD_SECONDS. */
const MIN_LEAD_SECONDS = 6
/** Do not decode further ahead than this; the lead is only needed for latency. */
const MAX_LEAD_SECONDS = 60
/** Pause decoding when Whisper is this far behind the hidden player. */
const MAX_BACKLOG_SECONDS = 45
const RESUME_BACKLOG_SECONDS = 30
/** Windows quieter than this are skipped instead of being sent to Whisper. */
const SPEECH_RMS = 0.004
const SILENT_CHUNKS_BEFORE_NOTICE = 40
const MAX_CUES = 1200

export class AutoCaptionSession {
  private context?: AudioContext
  private worker?: Worker
  private node?: AudioWorkletNode
  private sink?: GainNode
  private hidden?: HTMLVideoElement
  private hls?: Hls
  private timer?: ReturnType<typeof setInterval>

  private chunks: { start: number; data: Float32Array }[] = []
  private nextStart: number | null = null
  private lastPlayhead = -1
  private nextId = 1
  private windows = new Map<number, { start: number; epoch: number }>()
  /** Bumped whenever the hidden player jumps, so late results are ignored. */
  private epoch = 0
  private pending = new Set<number>()
  private cues: Cue[] = []
  private silentChunks = 0
  private placed = false
  private backlogged = false
  private disposed = false

  constructor(
    private main: HTMLVideoElement,
    private media: CaptionMedia,
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
      if (this.disposed) return
      this.node = new AudioWorkletNode(this.context, 'caption-tap', {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        channelCount: 1
      })
      this.node.port.onmessage = event => this.append(event.data as Float32Array)
      // The hidden element's output is routed through this graph and then
      // silenced, so nothing is audible.
      this.sink = this.context.createGain()
      this.sink.gain.value = 0
      this.node.connect(this.sink).connect(this.context.destination)

      this.attachHidden()
      await this.context.resume()
      this.timer = setInterval(() => this.tick(), 400)
    } catch (error) {
      this.fail(error instanceof Error ? error.message : String(error))
    }
  }

  private attachHidden() {
    const video = document.createElement('video')
    video.preload = 'auto'
    video.playsInline = true
    // The main process adds CORS headers for the app's media requests, so an
    // anonymous CORS fetch keeps the audio readable by Web Audio.
    video.crossOrigin = 'anonymous'
    video.onerror = () => this.fail('The video could not be read for captions.')
    this.hidden = video

    const source = this.context!.createMediaElementSource(video)
    source.connect(this.node!)

    if (this.media.hls && Hls.isSupported()) {
      const hls = new Hls({ enableWorker: true, maxBufferLength: 30, startFragPrefetch: true })
      this.hls = hls
      hls.on(Hls.Events.ERROR, (_event, data) => {
        if (!data.fatal) return
        if (data.type === Hls.ErrorTypes.NETWORK_ERROR) hls.startLoad()
        else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) hls.recoverMediaError()
        else this.fail(`Caption audio stream failed (${data.details}).`)
      })
      hls.subtitleDisplay = false
      hls.loadSource(this.media.url)
      hls.attachMedia(video)
    } else {
      video.src = this.media.url
    }
  }

  /** Keeps the hidden player in front of the visible one. */
  private tick() {
    const hidden = this.hidden
    const main = this.main
    if (this.disposed || !hidden) return
    if (!Number.isFinite(main.currentTime) || hidden.readyState < 1) return

    if (!this.placed) {
      this.placed = true
      this.seekHidden(main.currentTime + LEAD_SECONDS)
    }
    const lead = hidden.currentTime - main.currentTime
    if (lead < MIN_LEAD_SECONDS || lead > MAX_LEAD_SECONDS + 15) {
      this.seekHidden(main.currentTime + LEAD_SECONDS)
    }

    const behind = this.nextStart == null ? 0 : hidden.currentTime - this.nextStart
    if (behind > MAX_BACKLOG_SECONDS) this.backlogged = true
    else if (behind < RESUME_BACKLOG_SECONDS) this.backlogged = false

    const wantPlay = lead < MAX_LEAD_SECONDS && !this.backlogged && !hidden.ended
    if (wantPlay && hidden.paused) hidden.play().catch(() => {})
    else if (!wantPlay && !hidden.paused) hidden.pause()
  }

  private seekHidden(time: number) {
    const hidden = this.hidden
    if (!hidden) return
    const duration = Number.isFinite(hidden.duration) ? hidden.duration : this.main.duration
    const target = Number.isFinite(duration) ? Math.min(time, Math.max(0, duration - 1)) : time
    hidden.currentTime = Math.max(0, target)
    this.resetAudio()
  }

  private resetAudio() {
    this.epoch++
    this.chunks = []
    this.nextStart = null
    this.lastPlayhead = -1
  }

  private append(samples: Float32Array) {
    const hidden = this.hidden
    if (this.disposed || !hidden || hidden.paused || hidden.ended || hidden.seeking) return
    const now = hidden.currentTime
    if (!Number.isFinite(now)) return
    // A jump (hls.js recovery, seek) invalidates the audio we collected.
    if (this.lastPlayhead >= 0 && Math.abs(now - this.lastPlayhead) > 2) this.resetAudio()
    this.lastPlayhead = now

    let peak = 0
    for (let i = 0; i < samples.length; i += 64) peak = Math.max(peak, Math.abs(samples[i]))
    this.silentChunks = peak < 1e-5 ? this.silentChunks + 1 : 0
    if (this.silentChunks === SILENT_CHUNKS_BEFORE_NOTICE) {
      this.emit({ status: 'loading', detail: 'No audio is coming from this video yet…' })
    }

    this.chunks.push({ start: now - samples.length / SAMPLE_RATE, data: samples })
    if (this.nextStart == null) this.nextStart = this.chunks[0].start
    this.maybeTranscribe()
  }

  private maybeTranscribe() {
    if (!this.worker || this.pending.size > 0 || this.nextStart == null || this.chunks.length === 0) return
    const last = this.chunks[this.chunks.length - 1]
    const available = last.start + last.data.length / SAMPLE_RATE
    if (available < this.nextStart + WINDOW_SECONDS) return

    const start = this.nextStart
    const samples = this.collect(start, WINDOW_SECONDS)
    if (!samples || rms(samples) < SPEECH_RMS) {
      // Nothing to transcribe here; drop any stale cue for the span and move on.
      this.advance(start + STRIDE_SECONDS)
      this.mergeCues(start, start + STRIDE_SECONDS, [])
      this.maybeTranscribe()
      return
    }
    const id = this.nextId++
    this.windows.set(id, { start, epoch: this.epoch })
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

  private advance(to: number) {
    this.nextStart = to
    this.chunks = this.chunks.filter(chunk => chunk.start + chunk.data.length / SAMPLE_RATE > to)
  }

  /** Replaces whatever the span [start, end) previously contained. */
  private mergeCues(start: number, end: number, fresh: Cue[]) {
    this.cues = this.cues.filter(cue => cue.end <= start + 0.25 || cue.start >= end - 0.25).concat(fresh)
    this.cues.sort((a, b) => a.start - b.start)
    if (this.cues.length > MAX_CUES) this.cues = this.cues.slice(-MAX_CUES)
    this.onCues(this.cues)
  }

  private receive(message: CaptionResponse) {
    if (this.disposed) return
    switch (message.type) {
      case 'progress':
        this.emit({ status: 'loading', detail: 'Downloading the on-device caption model…', progress: message.loaded / message.total })
        break
      case 'ready':
        this.emit({ status: 'loading', detail: 'Listening ahead for speech… captions start in about 20 seconds.', progress: 1 })
        break
      case 'result': {
        this.pending.delete(message.id)
        const window = this.windows.get(message.id)
        this.windows.delete(message.id)
        if (!window || window.epoch !== this.epoch) {
          this.maybeTranscribe()
          break
        }
        const start = window.start
        // Commit only segments that finished well before the end of the
        // window; the rest is redone by the next window, which starts where
        // the last committed segment ended (a natural pause, not mid-sentence).
        const complete = message.chunks.filter(chunk => chunk.end <= WINDOW_SECONDS - TAIL_SECONDS)
        const committed = complete.length > 0 ? complete : message.chunks.filter(chunk => chunk.start < STRIDE_SECONDS)
        const commitEnd = complete.length > 0
          ? Math.max(...complete.map(chunk => chunk.end))
          : STRIDE_SECONDS
        const fresh: Cue[] = committed.map(chunk => ({
          start: start + chunk.start,
          end: Math.max(start + chunk.end, start + chunk.start + 1),
          text: chunk.text
        }))
        // Always move forward, even if the model returned nothing.
        const advanceBy = Math.max(commitEnd, 1)
        this.advance(start + advanceBy)
        this.mergeCues(start, start + advanceBy, fresh)
        if (fresh.length > 0) this.emit({ status: 'ready' })
        this.maybeTranscribe()
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
    if (this.timer) clearInterval(this.timer)
    this.hidden?.pause()
    this.hls?.destroy()
    if (this.hidden) {
      this.hidden.removeAttribute('src')
      this.hidden.load()
    }
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

function rms(samples: Float32Array): number {
  let sum = 0
  for (let i = 0; i < samples.length; i += 4) sum += samples[i] * samples[i]
  return Math.sqrt(sum / (samples.length / 4))
}
