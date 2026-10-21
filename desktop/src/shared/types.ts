// Shared shapes between main, preload and renderer. Field names mirror the
// iOS app's Codable models so backups move between platforms unchanged.

export type MediaType = 'movie' | 'tv'

export interface MediaItem {
  tmdbId: string
  type: MediaType
  title: string
  description: string
  posterPath?: string | null
  backdropPath?: string | null
  rating?: number | null
  year: string
  popularity: number
  resumeSeason?: number | null
  resumeEpisode?: number | null
  resumeTitle?: string | null
  /** ISO-8601 */
  updatedAt?: string | null
  anime?: boolean | null
}

export interface MediaRow {
  title: string
  subtitle: string
  items: MediaItem[]
}

export interface WatchProgress {
  /** "movie:123" or "tv:456:2:3" */
  id: string
  position: number
  duration: number
  /** ISO-8601 */
  lastWatchedAt: string
  completed: boolean
}

export interface StreamServer {
  id: string
  name: string
  base: string
}

export type AnimeServer = StreamServer

export interface ExternalSubtitle {
  label: string
  url: string
  referer: string
}

/** A skippable part of an episode, in seconds. See shared/introSkip.ts. */
export interface SkipSegment {
  /** Only intros are skipped today; outros (credits / ED) are kept for later. */
  kind: 'intro' | 'outro'
  start: number
  end: number
  source: 'stream' | 'theintrodb' | 'aniskip'
}

export interface ResolvedStream {
  id: string
  name: string
  url: string
  requestHeaders: Record<string, string>
  audio?: 'Sub' | 'Dub'
  quality?: string
  subtitles: ExternalSubtitle[]
  /** Timestamps the host ships with this exact stream (anime). */
  segments?: SkipSegment[]
}

export interface AnimeShow {
  slug: string
  title: string
  japaneseTitle: string
  posterURL: string
  kind: string
  subCount?: number
  dubCount?: number
}

export interface AnimeEpisode {
  number: string
  title: string
  ids: string
  hasSub: boolean
  hasDub: boolean
}

export interface AnimeDetails {
  show: AnimeShow
  description: string
  episodes: AnimeEpisode[]
  /** What the watch page says about the show; used to find its MAL id. */
  identity?: import('./introSkip').AnimeIdentity
}

export interface UpdateCheckResult {
  updateAvailable?: boolean
  currentVersion?: string
  latestVersion?: string
  /** Setup .exe asset of the latest GitHub release. */
  downloadUrl?: string
  /** Release page, opened when the installer can't be run. */
  releaseUrl?: string
  notes?: string
  error?: string
}

export interface SniffedStream {
  url: string
  referer?: string
}

export type MenuCommand =
  | 'home' | 'anime' | 'favorites' | 'settings' | 'search' | 'refresh'
  | 'toggle-sidebar' | 'back' | 'forward' | 'play-pause' | 'fullscreen'
  | 'export' | 'import' | 'check-updates' | 'about' | 'join-party'

/** API exposed on `window.vela` by the preload script. */
export interface VelaApi {
  platform: string
  version: string
  tmdb(path: string, params: Record<string, string | number | undefined>, credential?: string): Promise<unknown>
  resolveStreams(pageUrl: string): Promise<ResolvedStream[]>
  anime: {
    list(base: string, path: string): Promise<AnimeShow[]>
    search(base: string, query: string): Promise<AnimeShow[]>
    details(base: string, slug: string): Promise<AnimeDetails>
    findSlug(base: string, title: string): Promise<string | null>
    streams(base: string, episodeIds: string): Promise<ResolvedStream[]>
  }
  skip: {
    /** TheIntroDB, by TMDB show id and TMDB season/episode. */
    tv(tmdbId: string, season: number, episode: number, duration: number): Promise<SkipSegment[]>
    /** AniSkip, by the MAL id verified from the catalogue identity. */
    anime(identity: import('./introSkip').AnimeIdentity, episode: string, duration: number): Promise<SkipSegment[]>
  }
  fetchText(url: string, headers: Record<string, string>): Promise<string>
  checkServer(url: string): Promise<boolean>
  setPlaybackHeaders(headers: Record<string, string> | null): Promise<void>
  window: {
    minimize(): void
    toggleMaximize(): void
    close(): void
    setFullScreen(on: boolean): void
    isMaximized(): Promise<boolean>
    openSettings(): void
    popupMenu(x: number, y: number): void
  }
  updater: {
    check(): Promise<UpdateCheckResult>
    apply(downloadUrl: string | undefined, releaseUrl: string | undefined): Promise<{ ok: boolean; error?: string }>
  }
  saveFile(name: string, contents: string): Promise<boolean>
  openFile(): Promise<string | null>
  openExternal(url: string): void
  on(channel: 'open-tmdb-id', cb: (id: string) => void): () => void
  on(channel: 'open-party', cb: (link: string) => void): () => void
  on(channel: 'menu', cb: (cmd: MenuCommand) => void): () => void
  on(channel: 'update-check-result', cb: (r: UpdateCheckResult) => void): () => void
  on(channel: 'update-download-progress', cb: (f: number) => void): () => void
  on(channel: 'embed-sniffed', cb: (s: SniffedStream) => void): () => void
  on(channel: 'maximized', cb: (m: boolean) => void): () => void
  on(channel: 'link', cb: (e: import('./link').LinkEvent) => void): () => void
  link: {
    status(): Promise<import('./link').LinkStatus | null>
    startPairing(): Promise<import('./link').LinkStatus | null>
    cancelPairing(): void
    disconnect(deviceId: string): void
    forget(deviceId: string): void
    update(deviceId: string, patch: { syncEnabled?: boolean; autoReconnect?: boolean; lastSync?: number }): void
    send(deviceId: string | null, msg: Record<string, unknown>): void
    action(action: 'sync-now' | 'fresh-copy-to' | 'fresh-copy-from', deviceId: string): void
  }
  embed: {
    state(): Promise<{ position: number; duration: number; playing: boolean } | null>
    control(action: 'play' | 'pause' | 'toggle' | 'seek' | 'skip', value?: number): Promise<boolean>
  }
  showMainWindow(): void
  pendingParty(): Promise<string | null>
}
