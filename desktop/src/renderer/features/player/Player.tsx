// Native player: <video> + hls.js with custom Vela controls. Mirrors the
// iOS player redesign: Quality / Server / Captions menus top-right, skip +
// play/pause centre, thickening timeline, hold for 2×, Next Episode in the
// last 90 seconds. Falls back to the server's web player in a sandboxed
// <webview> when no direct stream can be resolved.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Hls from 'hls.js'
import { Icon } from '@/components/Icon'
import { MenuButton, MenuItem } from '@/components/Media'
import { recordProgress, usePlayer } from '@/stores/player'
import { useSettings } from '@/stores/settings'
import { captionAt, parseVtt, type Cue } from '@/lib/vtt'
import { cx, formatTime } from '@/lib/format'
import { imageUrl } from '@/lib/tmdb'
import { registerPlayer } from '@/lib/remote'

type Caption = { kind: 'off' } | { kind: 'external'; index: number } | { kind: 'hls'; index: number }

export function Player() {
  const p = usePlayer()
  const servers = useSettings(s => (p.kind === 'anime' ? s.animeServers : s.servers))
  const seekInterval = useSettings(s => s.seekInterval)
  const volume = useSettings(s => s.volume)
  const muted = useSettings(s => s.muted)
  const setSettings = useSettings(s => s.set)
  const captionScale = useSettings(s => s.captionScale ?? 1)

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
  const [skipFx, setSkipFx] = useState<{ dir: -1 | 1; amount: number; key: number } | null>(null)
  const [spin, setSpin] = useState<{ back: number; fwd: number }>({ back: 0, fwd: 0 })
  const [caption, setCaption] = useState<Caption>({ kind: 'off' })
  const [cues, setCues] = useState<Cue[]>([])
  const [hlsTracks, setHlsTracks] = useState<string[]>([])

  const source = p.sources[p.sourceIndex]
  const native = !!source

  // ── Load source ─────────────────────────────────────────────────────
  useEffect(() => {
    const v = video.current
    if (!v || !source) return
    started.current = false
    setTime(0); setDuration(0); setBuffered(0); setWaiting(true); setHlsTracks([])
    hls.current?.destroy(); hls.current = null

    const fail = (why: string) => usePlayer.getState().rejectCurrent(why)
    const isHls = /\.m3u8|\/hls|playlist|master/i.test(source.url) || !/\.(mp4|webm|mov)(\?|$)/i.test(source.url)
    if (isHls && Hls.isSupported()) {
      const h = new Hls({ enableWorker: true, maxBufferLength: 45, startFragPrefetch: true })
      hls.current = h
      h.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, (_e, d) => setHlsTracks(d.subtitleTracks.map(t => t.name || t.lang || 'Subtitles')))
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
    setCaption(source.audio === 'Sub' && source.subtitles.length ? { kind: 'external', index: Math.max(0, english) } : { kind: 'off' })

    return () => { h_destroy() }
    function h_destroy() { hls.current?.destroy(); hls.current = null; v!.removeAttribute('src'); v!.load() }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [p.loadToken])

  // ── External captions ───────────────────────────────────────────────
  useEffect(() => {
    setCues([])
    if (hls.current) hls.current.subtitleTrack = caption.kind === 'hls' ? caption.index : -1
    if (hls.current) hls.current.subtitleDisplay = caption.kind === 'hls'
    if (caption.kind !== 'external' || !source) return
    const track = source.subtitles[caption.index]
    if (!track) return
    let live = true
    window.vela.fetchText(track.url, { Referer: track.referer }).then(t => live && setCues(parseVtt(t))).catch(() => {})
    return () => { live = false }
  }, [caption, source])

  useEffect(() => { if (video.current) { video.current.volume = volume; video.current.muted = muted } }, [volume, muted, p.loadToken])

  // ── Progress + media session ────────────────────────────────────────
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
    ms.setActionHandler('nexttrack', usePlayer.getState().hasNext() ? () => usePlayer.getState().next() : null)
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
  const skip = useCallback((dir: -1 | 1) => {
    const v = video.current
    if (!v) return
    const now = Date.now()
    const acc = skipAccum.current
    acc.amount = acc.dir === dir && now - acc.t < 900 ? acc.amount + seekInterval : seekInterval
    acc.dir = dir; acc.t = now
    v.currentTime = Math.max(0, Math.min((v.duration || Infinity) - 0.5, v.currentTime + dir * seekInterval))
    setSkipFx({ dir, amount: acc.amount, key: now })
    setSpin(s => (dir < 0 ? { ...s, back: s.back + 1 } : { ...s, fwd: s.fwd + 1 }))
    poke()
  }, [seekInterval, poke])

  const toggle = useCallback(() => { const v = video.current; if (!v) return; v.paused ? v.play().catch(() => {}) : v.pause() }, [])
  const toggleFullscreen = useCallback(() => {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
    else root.current?.requestFullscreen().catch(() => {})
  }, [])
  const close = useCallback(() => {
    save()
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
    usePlayer.getState().close()
  }, [save])

  // Lets a paired phone drive this player (see lib/remote.ts).
  useEffect(() => registerPlayer({
    state: () => {
      const v = video.current
      return v && v.readyState > 0 ? { position: v.currentTime, duration: Number.isFinite(v.duration) ? v.duration : 0, playing: !v.paused && !v.ended } : null
    },
    play: () => { video.current?.play().catch(() => {}) },
    pause: () => video.current?.pause(),
    toggle,
    seek: to => { const v = video.current; if (v) v.currentTime = Math.max(0, Math.min(to, (v.duration || to + 1) - 0.5)) },
    skip: by => { const v = video.current; if (v) v.currentTime = Math.max(0, Math.min(v.currentTime + by, (v.duration || Infinity) - 0.5)) }
  }), [toggle])

  useEffect(() => {
    const onFs = () => setFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', onFs)
    return () => document.removeEventListener('fullscreenchange', onFs)
  }, [])

  // ── Keyboard ────────────────────────────────────────────────────────
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.tagName === 'INPUT' || e.ctrlKey || e.metaKey || e.altKey) return
      const v = video.current
      switch (e.key) {
        case ' ': case 'k': case 'K': if (native) { e.preventDefault(); toggle() } break
        case 'ArrowLeft': case 'j': case 'J': if (native) { e.preventDefault(); skip(-1) } break
        case 'ArrowRight': case 'l': case 'L': if (native) { e.preventDefault(); skip(1) } break
        case 'ArrowUp': e.preventDefault(); setSettings({ volume: Math.min(1, volume + 0.1), muted: false }); break
        case 'ArrowDown': e.preventDefault(); setSettings({ volume: Math.max(0, volume - 0.1) }); break
        case 'm': case 'M': setSettings({ muted: !muted }); break
        case 'f': case 'F': toggleFullscreen(); break
        case 'n': case 'N': if (usePlayer.getState().hasNext()) usePlayer.getState().next(); break
        case 'c': case 'C':
          if (source?.subtitles.length) setCaption(c => (c.kind === 'off' ? { kind: 'external', index: 0 } : { kind: 'off' }))
          break
        case 'Escape': if (!document.fullscreenElement) close(); break
        default: if (/^[0-9]$/.test(e.key) && v?.duration) v.currentTime = (Number(e.key) / 10) * v.duration
      }
      poke()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [native, toggle, skip, toggleFullscreen, close, poke, setSettings, volume, muted, source])

  // ── Click / double-click / hold-for-2× on the video surface ─────────
  const holdTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const held = useRef(false)
  const clickTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const onDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return
    held.current = false
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
    if (e.detail === 2) { clearTimeout(clickTimer.current); toggleFullscreen(); return }
    clickTimer.current = setTimeout(toggle, 200)
  }

  // ── Timeline ────────────────────────────────────────────────────────
  const bar = useRef<HTMLDivElement>(null)
  const fraction = (clientX: number) => {
    const r = bar.current!.getBoundingClientRect()
    return Math.max(0, Math.min(1, (clientX - r.left) / r.width))
  }
  const onBarDown = (e: React.PointerEvent) => {
    if (!duration) return
    e.currentTarget.setPointerCapture(e.pointerId)
    setScrub(fraction(e.clientX))
  }
  const onBarMove = (e: React.PointerEvent) => { if (scrub !== null) setScrub(fraction(e.clientX)) }
  const onBarUp = () => {
    if (scrub !== null && video.current) video.current.currentTime = scrub * duration
    setScrub(null)
  }

  const shown = scrub !== null ? scrub * duration : time
  const caption_text = caption.kind === 'external' ? captionAt(cues, time) : null
  const showNext = native && duration > 0 && duration - time <= 90 && usePlayer.getState().hasNext()

  const grouped = useMemo(() => {
    const sub = p.sources.map((s, i) => ({ s, i })).filter(x => x.s.audio === 'Sub')
    const dub = p.sources.map((s, i) => ({ s, i })).filter(x => x.s.audio === 'Dub')
    const other = p.sources.map((s, i) => ({ s, i })).filter(x => !x.s.audio)
    return { sub, dub, other }
  }, [p.sources])

  const qualityLabel = source ? (source.quality ? `${source.quality}${source.audio ? ' · ' + source.audio : ''}` : source.name) : 'Quality'

  return (
    <div ref={root} className={cx('player', !controls && 'is-idle', fullscreen && 'is-fullscreen')} onMouseMove={poke}
      style={{ '--caption-scale': captionScale } as React.CSSProperties} role="dialog" aria-label={`Playing ${p.item?.title ?? ''}`}>
      {native ? (
        <video
          ref={video}
          className="player-video"
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
            if (v.buffered.length) setBuffered(v.buffered.end(v.buffered.length - 1))
            if (Date.now() - lastSave.current > 5000) { lastSave.current = Date.now(); save() }
          }}
          onEnded={() => { save(); if (usePlayer.getState().hasNext()) usePlayer.getState().next() }}
        />
      ) : p.embedUrl ? (
        <webview key={p.embedUrl} className="player-embed" src={p.embedUrl} partition="persist:embed" webpreferences="contextIsolation=yes,sandbox=yes" />
      ) : <div className="player-video" />}

      {native && <div className="player-surface" onMouseDown={onDown} onMouseUp={onUp} onMouseLeave={onUp} onClick={onClick} />}

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
      {fastBadge && <div className="fast-badge glass-strong">2× <Icon name="next" size={12} fill /></div>}
      {skipFx && <div key={skipFx.key} className={cx('skip-fx', skipFx.dir < 0 ? 'is-left' : 'is-right')}>{skipFx.dir < 0 ? '−' : '+'}{skipFx.amount}s</div>}

      {/* Top bar */}
      <div className="player-top">
        <button className="round-btn" aria-label="Close player" title="Close (Esc)" onClick={close}><Icon name="chevronLeft" size={18} stroke={2.2} /></button>
        <div className="player-titles">
          <div className="player-title clamp-1">{p.item?.title}</div>
          {p.subtitle && <div className="player-subtitle clamp-1">{p.subtitle}</div>}
        </div>
        <div className="player-menus">
          {p.sources.length > 1 && (
            <MenuButton label={qualityLabel} icon="quality">
              {close => (
                <>
                  {(['sub', 'dub', 'other'] as const).map(g => grouped[g].length > 0 && (
                    <div key={g}>
                      {g !== 'other' && <div className="menu-label">{g === 'sub' ? 'Subtitled' : 'Dubbed'}</div>}
                      {grouped[g].map(({ s, i }) => (
                        <MenuItem key={s.id} selected={i === p.sourceIndex} disabled={p.rejected.includes(s.url)} onSelect={() => { save(); p.selectSource(i); close() }}>{s.quality ?? s.name}</MenuItem>
                      ))}
                    </div>
                  ))}
                </>
              )}
            </MenuButton>
          )}
          <MenuButton label={servers[p.serverIndex]?.name ?? 'Server'} icon="server">
            {close => (
              <>
                <div className="menu-label">{p.kind === 'anime' ? 'Anime servers' : 'Servers'}</div>
                {servers.map((s, i) => <MenuItem key={s.id} selected={i === p.serverIndex} onSelect={() => { save(); p.selectServer(i); close() }}>{s.name}</MenuItem>)}
              </>
            )}
          </MenuButton>
          {native && (source.subtitles.length > 0 || hlsTracks.length > 0) && (
            <MenuButton label={caption.kind === 'off' ? 'Captions off' : caption.kind === 'external' ? source.subtitles[caption.index]?.label ?? 'Captions' : hlsTracks[caption.index]} icon="captions">
              {close => (
                <>
                  <MenuItem selected={caption.kind === 'off'} onSelect={() => { setCaption({ kind: 'off' }); close() }}>Off</MenuItem>
                  {source.subtitles.map((t, i) => <MenuItem key={t.url} selected={caption.kind === 'external' && caption.index === i} onSelect={() => { setCaption({ kind: 'external', index: i }); close() }}>{t.label}</MenuItem>)}
                  {hlsTracks.map((t, i) => <MenuItem key={'h' + i} selected={caption.kind === 'hls' && caption.index === i} onSelect={() => { setCaption({ kind: 'hls', index: i }); close() }}>{t}</MenuItem>)}
                </>
              )}
            </MenuButton>
          )}
          {native && document.pictureInPictureEnabled && (
            <button className="round-btn" aria-label="Picture in picture" title="Picture in picture" onClick={() => {
              if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {})
              else video.current?.requestPictureInPicture().catch(() => {})
            }}><Icon name="pip" size={16} /></button>
          )}
          <button className="round-btn" aria-label={fullscreen ? 'Exit full screen' : 'Full screen'} title="Full screen (F)" onClick={toggleFullscreen}>
            <Icon name={fullscreen ? 'exitFullscreen' : 'fullscreen'} size={16} />
          </button>
        </div>
      </div>

      {native && (
        <>
          {/* Centre transport */}
          <div className="player-transport">
            <button className="round-btn big" aria-label={`Back ${seekInterval} seconds`} onClick={() => skip(-1)}>
              <SkipGlyph dir={-1} seconds={seekInterval} spin={spin.back} />
            </button>
            <button className="round-btn huge" aria-label={playing ? 'Pause' : 'Play'} onClick={toggle}>
              <Icon name={playing ? 'pause' : 'play'} size={30} fill stroke={0} />
            </button>
            <button className="round-btn big" aria-label={`Forward ${seekInterval} seconds`} onClick={() => skip(1)}>
              <SkipGlyph dir={1} seconds={seekInterval} spin={spin.fwd} />
            </button>
          </div>

          {/* Bottom */}
          <div className="player-bottom">
            {showNext && (
              <button className="btn btn-primary next-ep" onClick={() => { save(); usePlayer.getState().next() }}>
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
              >
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
