// Native player: <video> + hls.js with custom Vela controls. Mirrors the
// iOS player redesign: Quality / Server / Captions menus top-right, skip +
// play/pause centre, thickening timeline, hold for 2×, Next Episode in the
// last five minutes. Falls back to the server's web player in a sandboxed
// <webview> when no direct stream can be resolved.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Hls from 'hls.js'
import { Icon } from '@/components/Icon'
import { recordProgress, usePlayer } from '@/stores/player'
import { useSettings } from '@/stores/settings'
import { captionAt, parseVtt, type Cue } from '@/lib/vtt'
import { cx, formatTime } from '@/lib/format'
import { imageUrl } from '@/lib/tmdb'
import { registerPlayer } from '@/lib/remote'
import { party, partyActive, useParty } from '@/lib/party'
import { PartyButton, PartyPanel } from '../party/PartyPanel'
import { useIntroSkip } from './useIntroSkip'
import { AutoCaptionSession, type CaptionLanguage, type GeneratedCaptionState } from './autoCaptions'
import { useZoom } from './useZoom'
import { useSystemCaptionStyle } from './useSystemCaptionStyle'
import { PlayerSettingsMenu, type SettingsPage } from './PlayerSettingsMenu'
import { guardPartyLeave } from '../party/ConfirmDialog'
import { CAPTION_SIZES } from '@/stores/settings'

type Caption =
  | { kind: 'off' }
  | { kind: 'external'; index: number }
  | { kind: 'hls'; index: number }
  | { kind: 'generated'; language: CaptionLanguage; translate: boolean }
const captionPreferenceKey = 'vela_caption_preference'
let captionPreference: { kind: Caption['kind']; label?: string; index?: number; language?: CaptionLanguage; translate?: boolean } | null = (() => {
  try {
    const saved = JSON.parse(localStorage.getItem(captionPreferenceKey) ?? 'null')
    return saved && ['off', 'external', 'hls', 'generated'].includes(saved.kind) ? saved : null
  } catch { return null }
})()

/** The last captions that were on, so the Captions button can turn them back on. */
const lastCaptionKey = 'vela_caption_last'
let lastCaption: typeof captionPreference = (() => {
  try {
    const saved = JSON.parse(localStorage.getItem(lastCaptionKey) ?? 'null')
    return saved && ['external', 'hls', 'generated'].includes(saved.kind) ? saved : null
  } catch { return null }
})()

/** Rotation stays where the user left it for the rest of the session. */
let sessionRotation = 0

type SkipSide = 'left' | 'right'
type SkipFxState = { amount: number; key: number; leaving?: boolean }

const generatedLabel = (language: CaptionLanguage, translate: boolean) =>
  language === 'ja' ? (translate ? 'Auto-generated · Japanese → English' : 'Auto-generated · Japanese') : 'Auto-generated · English'

/** Probed streams say what they are; others are guessed from the URL. */
function sourceIsHls(source: { format?: string; url: string }): boolean {
  return source.format
    ? source.format === 'hls'
    : /\.m3u8|\/hls|playlist|master/i.test(source.url) || !/\.(mp4|webm|mov|mkv)(\?|$)/i.test(source.url)
}
export function Player() {
  const p = usePlayer()
  const servers = useSettings(s => (p.kind === 'anime' ? s.animeServers : s.servers))
  const seekInterval = useSettings(s => s.seekInterval)
  const volume = useSettings(s => s.volume)
  const muted = useSettings(s => s.muted)
  const setSettings = useSettings(s => s.set)
  const captionScale = useSettings(s => s.captionScale ?? 1)
  const partyWaiting = useParty(s => s.waitingOn)
  const partyStatus = useParty(s => (s.active ? s.status : 'closed'))
  const partyLocked = useParty(s => s.active && !s.canControl)

  const root = useRef<HTMLDivElement>(null)
  const video = useRef<HTMLVideoElement>(null)
  const hls = useRef<Hls | null>(null)
  const started = useRef(false)

  const [playing, setPlaying] = useState(false)
  const [time, setTime] = useState(0)
  const [duration, setDuration] = useState(0)
  const [buffered, setBuffered] = useState(0)
  const [waiting, setWaiting] = useState(false)
  const [controls, setControls] = useState(true)
  const [scrub, setScrub] = useState<number | null>(null)
  const [fullscreen, setFullscreen] = useState(false)
  const [fast, setFast] = useState(false)
  const [fastBadge, setFastBadge] = useState(false)
  // Each side has its own skip indicator, so a left skip never slides into a
  // right one: they fade in and out independently.
  const [skipFx, setSkipFx] = useState<Record<SkipSide, SkipFxState | null>>({ left: null, right: null })
  const [playFx, setPlayFx] = useState<{ playing: boolean; key: number } | null>(null)
  const [rotation, setRotation] = useState(sessionRotation)
  const rotateClockwise = useSettings(s => s.rotateClockwise ?? true)
  const minimized = p.minimized
  const zoom = useZoom(root, video, rotation)
  const captionStyle = useSystemCaptionStyle()
  const [spin, setSpin] = useState<{ back: number; fwd: number }>({ back: 0, fwd: 0 })
  const [caption, setCaption] = useState<Caption>({ kind: 'off' })
  const [cues, setCues] = useState<Cue[]>([])
  const [hlsTracks, setHlsTracks] = useState<string[]>([])
  const [hlsCaption, setHlsCaption] = useState<string | null>(null)
  const [genCues, setGenCues] = useState<Cue[]>([])
  const [genState, setGenState] = useState<GeneratedCaptionState>({ status: 'idle' })

  const source = p.sources[p.sourceIndex]
  const native = !!source
  const chooseCaption = (choice: Caption) => {
    captionPreference = choice.kind === 'external'
      ? { kind: 'external', label: source?.subtitles[choice.index]?.label, index: choice.index }
      : choice.kind === 'hls'
        ? { kind: 'hls', label: hlsTracks[choice.index], index: choice.index }
        : choice.kind === 'generated'
          ? { kind: 'generated', language: choice.language, translate: choice.translate }
          : { kind: 'off' }
    localStorage.setItem(captionPreferenceKey, JSON.stringify(captionPreference))
    if (captionPreference.kind !== 'off') {
      lastCaption = captionPreference
      localStorage.setItem(lastCaptionKey, JSON.stringify(lastCaption))
    }
    setCaption(choice)
  }

  /** The Captions button: off, or back to whatever was on last time. */
  const toggleCaptions = () => {
    if (caption.kind !== 'off') { chooseCaption({ kind: 'off' }); return }
    const subs = source?.subtitles ?? []
    const last = lastCaption
    if (last?.kind === 'external') {
      const i = subs.findIndex(t => t.label === last.label)
      if (i >= 0) { chooseCaption({ kind: 'external', index: i }); return }
    }
    if (last?.kind === 'hls') {
      const i = hlsTracks.findIndex(t => t === last.label)
      if (i >= 0) { chooseCaption({ kind: 'hls', index: i }); return }
    }
    if (last?.kind === 'generated') {
      const japanese = last.language === 'ja' && p.kind === 'anime'
      chooseCaption({ kind: 'generated', language: japanese ? 'ja' : 'en', translate: japanese && !!last.translate })
      return
    }
    const english = subs.findIndex(t => /english/i.test(t.label))
    if (subs.length) { chooseCaption({ kind: 'external', index: Math.max(0, english) }); return }
    const englishHls = hlsTracks.findIndex(t => /english|eng\b|^en\b/i.test(t))
    if (hlsTracks.length) { chooseCaption({ kind: 'hls', index: Math.max(0, englishHls) }); return }
    chooseCaption({ kind: 'generated', language: 'en', translate: false })
  }

  // ── Load source ─────────────────────────────────────────────────────
  useEffect(() => {
    const v = video.current
    if (!v || !source) return
    started.current = false
    setTime(0); setDuration(0); setBuffered(0); setWaiting(true); setHlsTracks([])
    hls.current?.destroy(); hls.current = null

    const fail = (why: string) => usePlayer.getState().rejectCurrent(why)
    // Probed streams say what they are; others are guessed from the URL.
    const isHls = sourceIsHls(source)
    if (isHls && Hls.isSupported()) {
      const h = new Hls({ enableWorker: true, maxBufferLength: 45, startFragPrefetch: true })
      hls.current = h
      h.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, (_e, d) => {
        const names = d.subtitleTracks.map(t => t.name || t.lang || 'Subtitles')
        setHlsTracks(names)
        if (captionPreference?.kind === 'hls') {
          const selected = names.findIndex(n => n === captionPreference?.label)
          const index = selected >= 0 ? selected : captionPreference.index ?? -1
          if (index >= 0 && index < names.length) { setCaption({ kind: 'hls', index }); h.subtitleTrack = index }
        }
      })
      h.on(Hls.Events.ERROR, (_e, d) => {
        if (!d.fatal) return
        if (started.current && d.type === Hls.ErrorTypes.NETWORK_ERROR) { h.startLoad(); return }
        if (started.current && d.type === Hls.ErrorTypes.MEDIA_ERROR) { h.recoverMediaError(); return }
        fail(d.details)
      })
      h.subtitleDisplay = false
      h.loadSource(source.url)
      h.attachMedia(v)
    } else {
      v.src = source.url
    }
    v.onerror = () => { if (!hls.current) fail('Video failed to load') }
    v.play().catch(() => {})

    // Soft subs switch on automatically for the subtitled track only.
    const english = source.subtitles.findIndex(t => /english/i.test(t.label))
    if (captionPreference?.kind === 'external') {
      const match = source.subtitles.findIndex(t => t.label === captionPreference?.label)
      const index = match >= 0 ? match : captionPreference.index ?? -1
      setCaption(index >= 0 && index < source.subtitles.length ? { kind: 'external', index } : { kind: 'off' })
    } else if (captionPreference?.kind === 'hls') {
      setCaption({ kind: 'hls', index: captionPreference.index ?? 0 })
    } else if (captionPreference?.kind === 'generated') {
      // Japanese is only offered for anime; anything else falls back to English.
      const japanese = captionPreference.language === 'ja' && p.kind === 'anime'
      setCaption({
        kind: 'generated',
        language: japanese ? 'ja' : 'en',
        translate: japanese && !!captionPreference.translate
      })
    } else if (captionPreference?.kind === 'off') {
      setCaption({ kind: 'off' })
    } else {
      setCaption(source.audio === 'Sub' && source.subtitles.length ? { kind: 'external', index: Math.max(0, english) } : { kind: 'off' })
    }

    return () => { h_destroy() }
    function h_destroy() { hls.current?.destroy(); hls.current = null; v!.removeAttribute('src'); v!.load() }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [p.loadToken])

  // ── External captions ───────────────────────────────────────────────
  useEffect(() => {
    setCues([])
    if (hls.current) hls.current.subtitleTrack = caption.kind === 'hls' ? caption.index : -1
    // Cues still load with display off ("hidden" mode); Vela draws them.
    if (hls.current) hls.current.subtitleDisplay = false
    setHlsCaption(null)
    if (caption.kind !== 'external' || !source) return
    const track = source.subtitles[caption.index]
    if (!track) return
    let live = true
    window.vela.fetchText(track.url, { Referer: track.referer }).then(t => live && setCues(parseVtt(t))).catch(() => {})
    return () => { live = false }
  }, [caption, source])

  useEffect(() => { if (video.current) { video.current.volume = volume; video.current.muted = muted } }, [volume, muted, p.loadToken])

  // ── Auto-generated captions ─────────────────────────────────────────
  // A session owns the audio tap + Whisper worker for as long as this caption
  // choice is active; changing source or track tears it down.
  useEffect(() => {
    setGenCues([])
    if (caption.kind !== 'generated' || !native) {
      setGenState({ status: 'idle' })
      return
    }
    const element = video.current
    if (!element) return
    if (!source) return
    const session = new AutoCaptionSession(
      element,
      { url: source.url, hls: sourceIsHls(source) },
      { language: caption.language, translate: caption.translate },
      setGenCues,
      setGenState
    )
    session.start()
    return () => session.dispose()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [caption, p.loadToken, native])

  // ── Progress + media session ────────────────────────────────────────
  const playNextRef = useRef<() => void>(() => {})
  const lastSave = useRef(0)
  const save = useCallback(() => {
    const v = video.current
    if (v && started.current && v.duration) recordProgress(usePlayer.getState().progressId, v.currentTime, v.duration)
  }, [])
  useEffect(() => () => save(), [save, p.loadToken])

  useEffect(() => {
    if (!p.item || !('mediaSession' in navigator)) return
    navigator.mediaSession.metadata = new MediaMetadata({
      title: p.item.title,
      artist: p.subtitle ?? 'Vela',
      artwork: p.item.posterPath ? [{ src: imageUrl(p.item.posterPath, 'w500'), sizes: '500x750' }] : []
    })
    const ms = navigator.mediaSession
    ms.setActionHandler('play', () => video.current?.play())
    ms.setActionHandler('pause', () => video.current?.pause())
    ms.setActionHandler('seekbackward', () => skip(-1))
    ms.setActionHandler('seekforward', () => skip(1))
    ms.setActionHandler('nexttrack', usePlayer.getState().hasNext() ? () => playNextRef.current() : null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [p.item, p.subtitle, p.loadToken])

  // ── Controls auto-hide ──────────────────────────────────────────────
  const hideTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const poke = useCallback(() => {
    setControls(true)
    clearTimeout(hideTimer.current)
    hideTimer.current = setTimeout(() => { if (!video.current?.paused && !root.current?.querySelector('.popover')) setControls(false) }, 2600)
  }, [])
  useEffect(() => { poke(); return () => clearTimeout(hideTimer.current) }, [poke, playing])

  // ── Actions ─────────────────────────────────────────────────────────
  const skipAccum = useRef<{ dir: number; amount: number; t: number }>({ dir: 0, amount: 0, t: 0 })
  // Every user seek goes through here: in a watch party it moves the room
  // (if this viewer may) and is mirrored locally; otherwise it's local only.
  const seekTo = useCallback((t: number) => {
    const v = video.current
    if (!v) return false
    const clamped = Math.max(0, Math.min((v.duration || Infinity) - 0.5, t))
    if (partyActive() && !party.seek(clamped)) return false
    v.currentTime = clamped
    return true
  }, [])

  const introSkip = useIntroSkip({ native, time, duration, seekTo })
  // Keyboard handler reads the latest intro without re-subscribing.
  const introSkipRef = useRef<(() => void) | null>(null)
  introSkipRef.current = introSkip.segment && !partyLocked ? introSkip.skip : null

  const skip = useCallback((dir: -1 | 1) => {
    const v = video.current
    if (!v) return
    const now = Date.now()
    const acc = skipAccum.current
    acc.amount = acc.dir === dir && now - acc.t < 900 ? acc.amount + seekInterval : seekInterval
    acc.dir = dir; acc.t = now
    if (!seekTo(v.currentTime + dir * seekInterval)) return
    const side: SkipSide = dir < 0 ? 'left' : 'right'
    setSkipFx(fx => ({ ...fx, [side]: { amount: acc.amount, key: now } }))
    setSpin(s => (dir < 0 ? { ...s, back: s.back + 1 } : { ...s, fwd: s.fwd + 1 }))
    poke()
  }, [seekInterval, poke, seekTo])

  const setPlaying_ = useCallback((on: boolean) => {
    const v = video.current
    if (!v) return
    if (partyActive() && !(on ? party.play() : party.pause())) return
    if (on) v.play().catch(() => {}); else v.pause()
  }, [])
  const toggle = useCallback(() => { const v = video.current; if (v) setPlaying_(v.paused) }, [setPlaying_])
  /** Click on the picture: play/pause with a quick centre flash, and show the controls. */
  const togglePicture = useCallback(() => {
    const v = video.current
    if (!v) return
    const willPlay = v.paused
    setPlaying_(willPlay)
    setPlayFx({ playing: willPlay, key: Date.now() })
    poke()
  }, [setPlaying_, poke])
  const rotate = useCallback(() => {
    setRotation(r => {
      const next = (r + (rotateClockwise ? 90 : -90) + 360) % 360
      sessionRotation = next
      return next
    })
    poke()
  }, [rotateClockwise, poke])
  const waitingRef = useRef(false)
  waitingRef.current = waiting
  const toggleFullscreen = useCallback(() => {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
    else root.current?.requestFullscreen().catch(() => {})
  }, [])
  /** Leaving the player keeps the video going in the mini-player. */
  const minimize = useCallback(() => {
    save()
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
    usePlayer.getState().minimize()
  }, [save])
  const close = useCallback(() => {
    // In a party: the host closing the player means "back to browsing" (the
    // room stays open); a viewer closing it leaves (lib/party.ts handles both).
    guardPartyLeave('Closing the player', () => {
      save()
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
      usePlayer.getState().close()
    })
  }, [save])
  const playNext = useCallback(() => {
    guardPartyLeave('Playing the next episode', () => { save(); usePlayer.getState().next() })
  }, [save])
  playNextRef.current = playNext

  // Caption list for the remote: side-loaded tracks first, then HLS tracks.
  const captionApi = useRef({ list: [] as string[], index: -1, set: (_i: number) => {} })
  captionApi.current = {
    list: [...(source?.subtitles.map(t => t.label) ?? []), ...hlsTracks],
    index: caption.kind === 'off' || caption.kind === 'generated' ? -1 : caption.kind === 'external' ? caption.index : (source?.subtitles.length ?? 0) + caption.index,
    set: (i: number) => {
      const ext = source?.subtitles.length ?? 0
      chooseCaption(i < 0 ? { kind: 'off' } : i < ext ? { kind: 'external', index: i } : { kind: 'hls', index: i - ext })
    }
  }

  // Lets a paired phone drive this player (see lib/remote.ts).
  useEffect(() => registerPlayer({
    captions: () => ({ list: captionApi.current.list, index: captionApi.current.index }),
    setCaption: i => captionApi.current.set(i),
    state: () => {
      const v = video.current
      return v && v.readyState > 0 ? { position: v.currentTime, duration: Number.isFinite(v.duration) ? v.duration : 0, playing: !v.paused && !v.ended } : null
    },
    play: () => setPlaying_(true),
    pause: () => setPlaying_(false),
    toggle,
    seek: to => { seekTo(to) },
    skip: by => { const v = video.current; if (v) seekTo(v.currentTime + by) },
    raw: {
      play: () => { video.current?.play().catch(() => {}) },
      pause: () => video.current?.pause(),
      seek: to => { const v = video.current; if (v) v.currentTime = Math.max(0, Math.min(to, (v.duration || to + 1) - 0.5)) },
      setRate: r => { const v = video.current; if (v && v.playbackRate !== r) v.playbackRate = r },
      waiting: () => waitingRef.current
    }
  }), [toggle, setPlaying_, seekTo])

  useEffect(() => {
    const onFs = () => setFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', onFs)
    return () => document.removeEventListener('fullscreenchange', onFs)
  }, [])

  // ── Keyboard ────────────────────────────────────────────────────────
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.tagName === 'INPUT' || e.ctrlKey || e.metaKey || e.altKey) return
      // The mini-player leaves the keyboard to the page being browsed.
      if (minimized) return
      const v = video.current
      switch (e.key) {
        case ' ': case 'k': case 'K': if (native) { e.preventDefault(); toggle() } break
        case 'ArrowLeft': case 'j': case 'J': if (native) { e.preventDefault(); skip(-1) } break
        case 'ArrowRight': case 'l': case 'L': if (native) { e.preventDefault(); skip(1) } break
        case 'ArrowUp': e.preventDefault(); setSettings({ volume: Math.min(1, volume + 0.1), muted: false }); break
        case 'ArrowDown': e.preventDefault(); setSettings({ volume: Math.max(0, volume - 0.1) }); break
        case 'm': case 'M': setSettings({ muted: !muted }); break
        case 'f': case 'F': toggleFullscreen(); break
        case 'n': case 'N': if (usePlayer.getState().hasNext()) playNext(); break
        case 's': case 'S': if (introSkipRef.current) { e.preventDefault(); introSkipRef.current() } break
        case 'c': case 'C': if (native) toggleCaptions(); break
        case 'z': case 'Z': if (native) zoom.toggleFill(); break
        case 'r': case 'R': if (native) rotate(); break
        case 'Escape': if (!document.fullscreenElement) minimize(); break
        default: if (/^[0-9]$/.test(e.key) && v?.duration) seekTo((Number(e.key) / 10) * v.duration)
      }
      poke()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [native, minimized, toggle, skip, seekTo, toggleFullscreen, minimize, playNext, poke, setSettings, volume, muted, source, caption, hlsTracks, zoom.toggleFill, rotate])

  // ── Click / double-click / hold-for-2× on the video surface ─────────
  const holdTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const held = useRef(false)
  const clickTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const onDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return
    held.current = false
    if (minimized) return
    // Hold-for-2× would pull this viewer out of a watch party's timeline.
    if (partyActive()) return
    holdTimer.current = setTimeout(() => {
      held.current = true
      const v = video.current
      if (v && !v.paused) { v.playbackRate = 2; setFast(true); setFastBadge(true); setTimeout(() => setFastBadge(false), 3000) }
    }, 380)
  }
  const onUp = () => {
    clearTimeout(holdTimer.current)
    if (held.current) { if (video.current) video.current.playbackRate = 1; setFast(false); setFastBadge(false) }
  }
  const onClick = (e: React.MouseEvent) => {
    if (held.current) return
    // The surface covers the letterbox bars too, so edges work anywhere.
    const r = e.currentTarget.getBoundingClientRect()
    const x = (e.clientX - r.left) / r.width
    const edge: -1 | 0 | 1 = x < 0.3 ? -1 : x > 0.7 ? 1 : 0
    if (minimized) { usePlayer.getState().expand(); return }
    if (e.detail >= 2) {
      clearTimeout(clickTimer.current)
      // Double-click the left/right edge to skip (keep clicking to add more),
      // the middle to toggle fullscreen.
      if (edge) skip(edge)
      else if (e.detail === 2) toggleFullscreen()
      return
    }
    // A short wait tells a single click from the start of a double-click.
    clickTimer.current = setTimeout(togglePicture, edge ? 220 : 180)
  }

  // ── Timeline ────────────────────────────────────────────────────────
  const bar = useRef<HTMLDivElement>(null)
  const [hover, setHover] = useState<number | null>(null)
  const fraction = (clientX: number) => {
    const r = bar.current!.getBoundingClientRect()
    return Math.max(0, Math.min(1, (clientX - r.left) / r.width))
  }
  const onBarDown = (e: React.PointerEvent) => {
    if (!duration) return
    e.currentTarget.setPointerCapture(e.pointerId)
    const at = fraction(e.clientX)
    setScrub(at)
    setHover(at)
  }
  const onBarMove = (e: React.PointerEvent) => {
    if (!duration) return
    const at = fraction(e.clientX)
    setHover(at)
    if (scrub !== null) setScrub(at)
  }
  const onBarUp = (e: React.PointerEvent) => {
    if (scrub !== null) seekTo(fraction(e.clientX) * duration)
    setScrub(null)
  }

  const shown = scrub !== null ? scrub * duration : time
  const caption_text = caption.kind === 'external' ? captionAt(cues, time)
    : caption.kind === 'hls' ? hlsCaption
      : caption.kind === 'generated' ? captionAt(genCues, time)
        : null
  const captionLabel = caption.kind === 'off' ? 'Captions off'
    : caption.kind === 'external' ? source?.subtitles[caption.index]?.label ?? 'Captions'
      : caption.kind === 'hls' ? hlsTracks[caption.index] ?? 'Captions'
        : generatedLabel(caption.language, caption.translate)
  const captionStatus = caption.kind === 'generated' && genState.status !== 'ready'
    ? genState.status === 'error'
      ? genState.detail ?? 'Auto-generated captions are unavailable for this video.'
      : `${genState.detail ?? 'Preparing on-device captions…'}${genState.progress != null && genState.progress < 1 ? ` ${Math.round(genState.progress * 100)}%` : ''}`
    : null
  const showNext = native && Number.isFinite(duration) && duration > 0 && duration - time <= 300 && usePlayer.getState().hasNext()

  const grouped = useMemo(() => {
    const sub = p.sources.map((s, i) => ({ s, i })).filter(x => x.s.audio === 'Sub')
    const dub = p.sources.map((s, i) => ({ s, i })).filter(x => x.s.audio === 'Dub')
    const other = p.sources.map((s, i) => ({ s, i })).filter(x => !x.s.audio)
    return { sub, dub, other }
  }, [p.sources])

  const qualityLabel = source ? (source.quality ? `${source.quality}${source.audio ? ' · ' + source.audio : ''}` : source.name) : 'Quality'
  const captionSizeLabel = CAPTION_SIZES.find(c => c.v === captionScale)?.label ?? 'Medium'

  const captionSections = native ? [
    { choices: [{ key: 'off', label: 'Off', selected: caption.kind === 'off', onSelect: () => chooseCaption({ kind: 'off' }) }] },
    {
      title: 'Auto-generated',
      note: captionStatus,
      choices: [
        { key: 'gen-en', label: 'English (auto-generated)', selected: caption.kind === 'generated' && caption.language === 'en', onSelect: () => chooseCaption({ kind: 'generated', language: 'en', translate: false }) },
        ...(p.kind === 'anime' ? [
          { key: 'gen-ja', label: 'Japanese (auto-generated)', selected: caption.kind === 'generated' && caption.language === 'ja' && !caption.translate, onSelect: () => chooseCaption({ kind: 'generated', language: 'ja', translate: false }) },
          { key: 'gen-ja-en', label: 'Japanese → English', selected: caption.kind === 'generated' && caption.language === 'ja' && caption.translate, onSelect: () => chooseCaption({ kind: 'generated', language: 'ja', translate: true }) }
        ] : [])
      ]
    },
    ...(source?.subtitles.length ? [{
      title: 'This video',
      choices: source.subtitles.map((t, i) => ({ key: 'x' + t.url, label: t.label, selected: caption.kind === 'external' && caption.index === i, onSelect: () => chooseCaption({ kind: 'external', index: i }) }))
    }] : []),
    ...(hlsTracks.length ? [{
      title: 'Stream',
      choices: hlsTracks.map((t, i) => ({ key: 'h' + i, label: t, selected: caption.kind === 'hls' && caption.index === i, onSelect: () => chooseCaption({ kind: 'hls', index: i }) }))
    }] : [])
  ] : []

  const settingsPages: SettingsPage[] = [
    ...(p.sources.length > 1 ? [{
      id: 'quality', icon: 'quality' as const, label: p.kind === 'anime' ? 'Quality' : 'Source', value: qualityLabel,
      sections: (['sub', 'dub', 'other'] as const).filter(g => grouped[g].length > 0).map(g => ({
        title: g === 'other' ? undefined : g === 'sub' ? 'Subtitled' : 'Dubbed',
        choices: grouped[g].map(({ s, i }) => ({ key: s.id, label: s.quality ?? s.name, selected: i === p.sourceIndex, disabled: p.rejected.includes(s.url), onSelect: () => { save(); p.selectSource(i) } }))
      }))
    }] : []),
    {
      id: 'server', icon: 'server', label: 'Server', value: servers[p.serverIndex]?.name,
      sections: [{ title: p.kind === 'anime' ? 'Anime servers' : 'Servers', choices: servers.map((s, i) => ({ key: s.id, label: s.name, selected: i === p.serverIndex, onSelect: () => { save(); p.selectServer(i) } })) }]
    },
    ...(native ? [
      { id: 'captions', icon: 'captions' as const, label: 'Captions', value: caption.kind === 'off' ? 'Off' : captionLabel, sections: captionSections },
      {
        id: 'caption-size', icon: 'textSize' as const, label: 'Caption size', value: captionSizeLabel,
        sections: [{ note: 'Colour, font and background follow Windows caption style.', choices: CAPTION_SIZES.map(c => ({ key: String(c.v), label: c.label, selected: captionScale === c.v, onSelect: () => setSettings({ captionScale: c.v }) })) }]
      },
      ...(window.vela.platform === 'win32' ? [{ id: 'caption-style', icon: 'external' as const, label: 'Caption style', value: 'Windows Settings', onSelect: () => window.vela.captions.openSettings() }] : []),
      { id: 'fill', icon: 'fill' as const, label: 'Zoom to fill', value: zoom.filled ? 'On' : 'Off', toggle: true, onSelect: zoom.toggleFill },
      {
        id: 'rotate-direction', icon: (rotateClockwise ? 'rotate' : 'rotateLeft') as 'rotate' | 'rotateLeft', label: 'Rotate direction', value: rotateClockwise ? 'Clockwise' : 'Counterclockwise',
        sections: [{ choices: [
          { key: 'cw', label: 'Clockwise', selected: rotateClockwise, onSelect: () => setSettings({ rotateClockwise: true }) },
          { key: 'ccw', label: 'Counterclockwise', selected: !rotateClockwise, onSelect: () => setSettings({ rotateClockwise: false }) }
        ] }]
      }
    ] : []),
    { id: 'more', icon: 'gear', label: 'More settings', external: true, onSelect: () => window.vela.window.openSettings() }
  ]

  return (
    <div ref={root}
      className={cx('player', !controls && !minimized && 'is-idle', fullscreen && 'is-fullscreen', minimized && 'is-mini', zoom.adjusting && 'is-zooming')}
      onMouseMove={minimized ? undefined : poke}
      style={{ '--caption-scale': captionScale, ...captionStyle } as React.CSSProperties}
      role={minimized ? 'region' : 'dialog'} aria-label={minimized ? `Mini player: ${p.item?.title ?? ''}` : `Playing ${p.item?.title ?? ''}`}>
      {native ? (
        <video
          ref={video}
          className="player-video"
          style={{ transform: minimized ? undefined : zoom.transform }}
          playsInline
          onPlay={() => setPlaying(true)}
          onPause={() => { setPlaying(false); save() }}
          onWaiting={() => setWaiting(true)}
          onPlaying={() => setWaiting(false)}
          onLoadedMetadata={e => {
            const v = e.currentTarget
            setDuration(v.duration || 0)
            const at = usePlayer.getState().resumeAt
            if (at > 0 && at < v.duration - 5) v.currentTime = at
          }}
          onDurationChange={e => setDuration(e.currentTarget.duration || 0)}
          onTimeUpdate={e => {
            const v = e.currentTarget
            if (!started.current && v.currentTime > 0.2) started.current = true
            setTime(v.currentTime)
            if (caption.kind === 'hls') {
              const lines: string[] = []
              for (const track of Array.from(v.textTracks)) {
                if (track.mode === 'disabled' || !track.activeCues) continue
                for (const cue of Array.from(track.activeCues)) {
                  const text = (cue as VTTCue).text?.replace(/<[^>]+>/g, '').trim()
                  if (text) lines.push(text)
                }
              }
              const next = lines.length ? lines.join('\n') : null
              setHlsCaption(c => (c === next ? c : next))
            }
            if (v.buffered.length) setBuffered(v.buffered.end(v.buffered.length - 1))
            if (Date.now() - lastSave.current > 5000) { lastSave.current = Date.now(); save() }
          }}
          onEnded={() => {
            save()
            // In a party only the leader advances; everyone else follows the room.
            if (partyActive()) party.ended()
            else if (usePlayer.getState().hasNext()) usePlayer.getState().next()
          }}
        />
      ) : p.embedUrl ? (
        <webview key={p.embedUrl} className="player-embed" src={p.embedUrl} partition="persist:embed" webpreferences="contextIsolation=yes,sandbox=yes" />
      ) : <div className="player-video" />}

      {native && <div className="player-surface" onMouseDown={onDown} onMouseUp={onUp} onMouseLeave={onUp} onClick={onClick}
        onWheel={minimized ? undefined : e => { zoom.onWheel(e); poke() }} />}

      {minimized && (
        <div className="mini-controls">
          {native && (
            <button className="round-btn mini-play" aria-label={playing ? 'Pause' : 'Play'} onClick={toggle}>
              <span key={String(playing)} className="play-icon"><Icon name={playing ? 'pause' : 'play'} size={18} fill stroke={0} /></span>
            </button>
          )}
          <button className="round-btn" aria-label="Expand player" title="Expand" onClick={() => usePlayer.getState().expand()}><Icon name="expand" size={14} /></button>
          <button className="round-btn" aria-label="Close player" title="Close" onClick={close}><Icon name="close" size={14} stroke={2.2} /></button>
        </div>
      )}
      {minimized && native && duration > 0 && <div className="mini-progress" aria-hidden="true"><div style={{ width: `${(time / duration) * 100}%` }} /></div>}

      {caption_text && <div className={cx('caption', controls && 'is-raised')}>{caption_text.split('\n').map((l, i) => <span key={i}>{l}</span>)}</div>}

      {(p.resolving || (native && waiting && !p.error)) && (
        <div className="player-center-status"><div className="spinner" />{p.status && <span>{p.status}</span>}</div>
      )}
      {p.error && (
        <div className="player-error glass-strong" role="alert">
          <strong>Can’t play this</strong>
          <p>{p.error}</p>
          <div className="hero-actions"><button className="btn btn-primary" onClick={p.reload}>Try again</button></div>
        </div>
      )}
      {!minimized && <PartyPanel />}
      {zoom.indicator && !minimized && <div key={zoom.indicator.includes('×') ? 'zoom' : zoom.indicator} className="zoom-badge glass-strong" role="status">{zoom.indicator}</div>}
      {playFx && !minimized && (
        <div key={playFx.key} className="play-fx" aria-hidden="true" onAnimationEnd={() => setPlayFx(null)}>
          <Icon name={playFx.playing ? 'play' : 'pause'} size={30} fill stroke={0} />
        </div>
      )}
      {partyWaiting.length > 0 && <div className="party-banner glass-strong" role="status">Waiting for {partyWaiting.slice(0, 3).join(', ')}{partyWaiting.length > 3 ? ` +${partyWaiting.length - 3}` : ''}…</div>}
      {partyStatus === 'reconnecting' && <div className="party-banner glass-strong" role="status">Reconnecting to the party…</div>}
      {captionStatus && <div className="caption-status glass-strong" role="status">{captionStatus}</div>}
      {fastBadge && <div className="fast-badge glass-strong">2× <Icon name="next" size={12} fill /></div>}
      {(['left', 'right'] as const).map(side => skipFx[side] && (
        <SkipIndicator key={side} side={side} fx={skipFx[side]!}
          onLeave={key => setSkipFx(fx => (fx[side]?.key === key ? { ...fx, [side]: { ...fx[side]!, leaving: true } } : fx))}
          onDone={key => setSkipFx(fx => (fx[side]?.key === key ? { ...fx, [side]: null } : fx))} />
      ))}

      {/* Top bar */}
      <div className="player-top">
        <button className="round-btn" aria-label="Back" title="Back (Esc) · keeps playing in the corner" onClick={minimize}><Icon name="chevronLeft" size={18} stroke={2.2} /></button>
        <div className="player-titles">
          <div className="player-title clamp-1">{p.item?.title}</div>
          {p.subtitle && <div className="player-subtitle clamp-1">{p.subtitle}</div>}
        </div>
        <div className="player-menus">
          <PartyButton />
          {native && document.pictureInPictureEnabled && (
            <button className="round-btn" aria-label="Picture in picture" title="Picture in picture" onClick={() => {
              if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {})
              else video.current?.requestPictureInPicture().catch(() => {})
            }}><Icon name="pip" size={16} /></button>
          )}
          {native && (
            <button className="round-btn" aria-label={`Rotate ${rotateClockwise ? 'clockwise' : 'counterclockwise'}`} title="Rotate (R)" onClick={rotate}>
              <Icon name={rotateClockwise ? 'rotate' : 'rotateLeft'} size={16} />
            </button>
          )}
          {native && (
            <button className={cx('round-btn', caption.kind !== 'off' && 'is-on')} aria-label="Captions" aria-pressed={caption.kind !== 'off'} title={`Captions (C) · ${caption.kind === 'off' ? 'Off' : captionLabel}`} onClick={() => { toggleCaptions(); poke() }}>
              <Icon name="captions" size={17} />
            </button>
          )}
          <PlayerSettingsMenu pages={settingsPages} onOpenChange={open => { if (!open) poke() }} />
          <button className="round-btn" aria-label={fullscreen ? 'Exit full screen' : 'Full screen'} title="Full screen (F)" onClick={toggleFullscreen}>
            <Icon name={fullscreen ? 'exitFullscreen' : 'fullscreen'} size={16} />
          </button>
        </div>
      </div>

      {introSkip.segment && !partyLocked && !p.error && (
        <button className={cx('btn btn-primary skip-intro', (introSkip.segment.kind === 'outro' || introSkip.segment.kind === 'preview') && 'is-secondary')} onClick={() => { introSkip.skip(); poke() }}>
          <span key={introSkip.segment.kind} className="skip-action-label"><Icon name="next" size={13} fill />Skip {introSkip.segment.kind[0].toUpperCase() + introSkip.segment.kind.slice(1)}</span>
        </button>
      )}

      {native && (
        <>
          {/* Centre transport */}
          <div className={cx('player-transport', partyLocked && 'is-locked')} title={partyLocked ? 'The host is controlling playback' : undefined}>
            <button className="round-btn big" aria-label={`Back ${seekInterval} seconds`} onClick={() => skip(-1)}>
              <SkipGlyph dir={-1} seconds={seekInterval} spin={spin.back} />
            </button>
            <button className="round-btn huge" aria-label={playing ? 'Pause' : 'Play'} onClick={toggle}>
              <span key={String(playing)} className="play-icon"><Icon name={playing ? 'pause' : 'play'} size={30} fill stroke={0} /></span>
            </button>
            <button className="round-btn big" aria-label={`Forward ${seekInterval} seconds`} onClick={() => skip(1)}>
              <SkipGlyph dir={1} seconds={seekInterval} spin={spin.fwd} />
            </button>
          </div>

          {/* Bottom */}
          <div className="player-bottom">
            {showNext && (
              <button className="btn btn-primary next-ep" onClick={playNext}>
                <Icon name="next" size={13} fill />Next Episode
              </button>
            )}
            <div className="timeline-row">
              <span className="time">{formatTime(shown)}</span>
              <div
                ref={bar}
                className={cx('timeline', scrub !== null && 'is-scrubbing')}
                role="slider" aria-label="Seek" aria-valuemin={0} aria-valuemax={Math.round(duration)} aria-valuenow={Math.round(shown)} aria-valuetext={formatTime(shown)} tabIndex={0}
                onPointerDown={onBarDown} onPointerMove={onBarMove} onPointerUp={onBarUp}
                onPointerEnter={onBarMove} onPointerLeave={() => setHover(null)} onPointerCancel={() => { setScrub(null); setHover(null) }}
              >
                {hover !== null && duration > 0 && <div className="timeline-preview" style={{ left: `clamp(25px, ${hover * 100}%, calc(100% - 25px))` }} aria-hidden="true">{formatTime(hover * duration)}</div>}
                <div className="timeline-track">
                  <div className="timeline-buffer" style={{ width: duration ? `${(buffered / duration) * 100}%` : 0 }} />
                  <div className="timeline-fill" style={{ width: duration ? `${(shown / duration) * 100}%` : 0 }} />
                </div>
              </div>
              <span className="time">-{formatTime(Math.max(0, duration - shown))}</span>
              <div className="volume">
                <button className="round-btn small" aria-label={muted ? 'Unmute' : 'Mute'} onClick={() => setSettings({ muted: !muted })}><Icon name={muted || volume === 0 ? 'mute' : 'volume'} size={15} /></button>
                <input type="range" min={0} max={1} step={0.02} value={muted ? 0 : volume} aria-label="Volume" onChange={e => setSettings({ volume: Number(e.target.value), muted: false })} />
              </div>
            </div>
          </div>
        </>
      )}
      {fast && <span className="sr-only" aria-live="polite">Playing at double speed</span>}
    </div>
  )
}

/**
 * One side's double-click skip indicator. Each side is its own layer with its
 * own timers: it holds briefly after the last press, then fades out.
 */
function SkipIndicator({ side, fx, onLeave, onDone }: { side: SkipSide; fx: SkipFxState; onLeave: (key: number) => void; onDone: (key: number) => void }) {
  useEffect(() => {
    // Leaving: transitionend removes it; the timer is the fallback if it never fires.
    const t = fx.leaving ? setTimeout(() => onDone(fx.key), 600) : setTimeout(() => onLeave(fx.key), 750)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fx.key, fx.leaving])
  return (
    <div className={cx('skip-fx', side === 'left' ? 'is-left' : 'is-right', fx.leaving && 'is-leaving')} aria-hidden="true"
      onTransitionEnd={e => { if (e.target === e.currentTarget && fx.leaving) onDone(fx.key) }}>
      {/* Re-keyed per press so the ripple and icon pulse restart; the layer only fades once. */}
      <div key={fx.key} className="skip-fx-ripple" />
      <div key={'l' + fx.key} className="skip-fx-label">
        <Icon name={side === 'left' ? 'chevronLeft' : 'chevronRight'} size={22} stroke={2.6} />
        {fx.amount} seconds
      </div>
    </div>
  )
}

function SkipGlyph({ dir, seconds, spin }: { dir: -1 | 1; seconds: number; spin: number }) {
  return (
    <span className="skip-glyph" style={{ transform: `rotate(${dir * spin * 360}deg)` }}>
      <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"
        style={dir < 0 ? undefined : { transform: 'scaleX(-1)' }}>
        <path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3" /><path d="M4 3.5v4h4" />
      </svg>
      <span className="skip-num">{seconds}</span>
    </span>
  )
}
