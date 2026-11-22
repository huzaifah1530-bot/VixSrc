// Local Whisper transcription for the Windows player. The model runs inside
// this worker (ONNX Runtime Web), so audio never leaves the machine and the
// UI thread stays free while a window is decoded.
import { pipeline, env, type AutomaticSpeechRecognitionPipeline } from '@huggingface/transformers'

export type CaptionRequest =
  | { type: 'load'; model?: string }
  | { type: 'audio'; id: number; samples: Float32Array; language: string; translate: boolean }
  | { type: 'reset' }

export type CaptionResponse =
  | { type: 'progress'; file?: string; loaded: number; total: number }
  | { type: 'ready' }
  | { type: 'result'; id: number; chunks: { start: number; end: number; text: string }[] }
  | { type: 'error'; message: string }

env.allowLocalModels = false
env.useBrowserCache = true

const MODEL = 'onnx-community/whisper-base'

const scope = self as unknown as { postMessage: (message: CaptionResponse) => void }

let asr: AutomaticSpeechRecognitionPipeline | null = null
let loading: Promise<AutomaticSpeechRecognitionPipeline> | null = null

const post = (message: CaptionResponse) => scope.postMessage(message)

function load(model: string): Promise<AutomaticSpeechRecognitionPipeline> {
  if (asr) return Promise.resolve(asr)
  if (!loading) {
    loading = pipeline('automatic-speech-recognition', model, {
      dtype: 'q8',
      progress_callback: (p: { status?: string; file?: string; loaded?: number; total?: number }) => {
        if (p.status === 'progress' && p.total) {
          post({ type: 'progress', file: p.file, loaded: p.loaded ?? 0, total: p.total })
        }
      }
    } as never)
      .then(model => {
        asr = model as unknown as AutomaticSpeechRecognitionPipeline
        post({ type: 'ready' })
        return asr
      })
      .catch(error => {
        loading = null
        throw error
      })
  }
  return loading
}

/** Grouping and punctuation are model output; numbers still get tidied. */
export function formatCaption(text: string): string {
  return text
    .trim()
    .replace(/\s+([,.!?;:])/g, '$1')
    .replace(/\b(\d{5,9})\b/g, n => Number(n).toLocaleString('en-US'))
}

type WhisperResult = {
  text?: string
  chunks?: { timestamp: [number, number | null]; text?: string }[]
}

self.onmessage = async (event: MessageEvent<CaptionRequest>) => {
  const msg = event.data
  if (msg.type === 'reset') {
    asr = null
    loading = null
    return
  }
  if (msg.type === 'load') {
    try {
      await load(msg.model ?? MODEL)
    } catch (error) {
      post({ type: 'error', message: error instanceof Error ? error.message : String(error) })
    }
    return
  }
  try {
    const model = await load(MODEL)
    const out = (await model(msg.samples, {
      return_timestamps: true,
      chunk_length_s: 30,
      stride_length_s: 5,
      language: msg.language,
      task: msg.translate ? 'translate' : 'transcribe'
    })) as unknown as WhisperResult
    const chunks = (out.chunks ?? [])
      .filter(chunk => Array.isArray(chunk.timestamp) && chunk.timestamp[0] != null)
      .map(chunk => ({
        start: Number(chunk.timestamp[0]),
        end: Number(chunk.timestamp[1] ?? chunk.timestamp[0]! + 2),
        text: formatCaption(chunk.text ?? '')
      }))
      .filter(chunk => chunk.text.length > 0)
    post({ type: 'result', id: msg.id, chunks })
  } catch (error) {
    post({ type: 'error', message: error instanceof Error ? error.message : String(error) })
  }
}
