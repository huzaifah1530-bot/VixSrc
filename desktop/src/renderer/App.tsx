import { useEffect } from 'react'
import type { MenuCommand } from '@shared/types'
import { Sidebar, Toolbar, useWindowFocusClass } from './components/Chrome'
import { ContextMenuHost, Toast } from './components/Media'
import { HomePage } from './features/home/HomePage'
import { AnimePage } from './features/anime/AnimePage'
import { AnimeDetailsPage } from './features/anime/AnimeDetailsPage'
import { DetailsPage } from './features/details/DetailsPage'
import { FavoritesPage } from './features/favorites/FavoritesPage'
import { Player } from './features/player/Player'
import { useNav, useRefresh, useSearch, toast } from './stores/ui'
import { useSettings } from './stores/settings'
import { usePlayer } from './stores/player'
import { exportBackup, importBackup } from './lib/backup'
import { normalize, tmdb, type RawTmdbItem } from './lib/tmdb'
import { cx } from './lib/format'
import { ConnectDialog, OfferDialog } from './features/devices/DeviceDialogs'
import { startLinkClient } from './stores/link'
import { create } from 'zustand'
import { joinParty } from './lib/party'
import { FollowPrompt, JoinPartyDialog, PartyDock, StartPartyDialog } from './features/party/PartyPanel'
import { UpdateDialog, useUpdate } from './features/update/UpdateDialog'

const useJoinDialog = create<{ open: boolean }>(() => ({ open: false }))

function runCommand(cmd: MenuCommand) {
  const nav = useNav.getState()
  const playerOpen = usePlayer.getState().open
  switch (cmd) {
    case 'home': case 'anime': case 'favorites':
      if (cmd === 'anime' && !useSettings.getState().animeEnabled) return
      if (playerOpen) usePlayer.getState().close()
      useSearch.getState().setQuery(''); nav.root({ name: cmd }); break
    case 'search': if (!playerOpen) useSearch.getState().focus(); break
    case 'refresh': useRefresh.getState().bump(); break
    case 'toggle-sidebar': useSettings.getState().set({ sidebarCollapsed: !useSettings.getState().sidebarCollapsed }); break
    case 'back': if (playerOpen) usePlayer.getState().close(); else nav.back(); break
    case 'forward': nav.forward(); break
    case 'settings': window.vela.window.openSettings(); break
    case 'export': exportBackup(); break
    case 'import': importBackup(); break
    case 'check-updates': case 'about':
      window.vela.updater.check().then(r => { if (r.updateAvailable) useUpdate.setState({ result: r }); else toast(r.error ? r.error : `Vela ${window.vela.version} is up to date`) })
      break
    case 'join-party': useJoinDialog.setState({ open: true }); break
    case 'play-pause': case 'fullscreen': break // handled by the player's own key handler
  }
}

async function openById(id: string) {
  for (const type of ['movie', 'tv'] as const) {
    try {
      const raw = await tmdb<RawTmdbItem>(`/${type}/${id}`)
      const item = normalize(raw, type)
      if (item) { useNav.getState().push({ name: 'details', item }); return }
    } catch { /* try the other type */ }
  }
  toast(`Couldn’t find TMDB title ${id}`)
}

export function App() {
  const route = useNav(s => s.route)
  const collapsed = useSettings(s => s.sidebarCollapsed)
  const perf = useSettings(s => s.performanceMode)
  const ultra = useSettings(s => s.ultraPerformanceMode)
  const animeEnabled = useSettings(s => s.animeEnabled)
  const playerOpen = usePlayer(s => s.open)
  const joinOpen = useJoinDialog(s => s.open)
  useWindowFocusClass()

  useEffect(() => {
    document.body.classList.toggle('perf', perf && !ultra)
    document.body.classList.toggle('ultra', ultra)
  }, [perf, ultra])

  // Leaving the anime section when anime is switched off.
  useEffect(() => {
    if (!animeEnabled && (route.name === 'anime' || route.name === 'anime-details')) useNav.getState().root({ name: 'home' })
  }, [animeEnabled, route.name])

  useEffect(() => startLinkClient(), [])

  // While anything scrolls, hover effects and preview timers are paused
  // (body.is-scrolling) so the GPU only has to move pixels, not restyle cards.
  useEffect(() => {
    let t: ReturnType<typeof setTimeout> | undefined
    const onScroll = () => {
      if (!t) document.body.classList.add('is-scrolling')
      clearTimeout(t)
      t = setTimeout(() => { document.body.classList.remove('is-scrolling'); t = undefined }, 140)
    }
    window.addEventListener('scroll', onScroll, { capture: true, passive: true })
    return () => { window.removeEventListener('scroll', onScroll, { capture: true }); clearTimeout(t) }
  }, [])

  useEffect(() => {
    const offs = [
      window.vela.on('menu', runCommand),
      window.vela.on('open-tmdb-id', openById),
      window.vela.on('open-party', link => { joinParty(link) }),
      (window.vela.pendingParty().then(l => { if (l) joinParty(l) }), () => {}),
      window.vela.on('update-check-result', r => { if (r.updateAvailable) useUpdate.setState({ result: r }) })
    ]
    return () => offs.forEach(o => o())
  }, [])

  // Keyboard shortcuts (the app menu lists them; it's popped from the toolbar).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const k = e.key.toLowerCase()
      if (e.ctrlKey && !e.shiftKey && !e.altKey) {
        const map: Record<string, MenuCommand> = { j: 'join-party', '1': 'home', '2': 'anime', '3': 'favorites', f: 'search', k: 'search', '\\': 'toggle-sidebar', ',': 'settings', r: 'refresh', e: 'export', o: 'import' }
        if (map[k]) { e.preventDefault(); runCommand(map[k]) }
      } else if (e.altKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
        e.preventDefault(); runCommand(e.key === 'ArrowLeft' ? 'back' : 'forward')
      } else if (e.key === 'BrowserBack') runCommand('back')
    }
    const onMouse = (e: MouseEvent) => { if (e.button === 3) runCommand('back'); if (e.button === 4) runCommand('forward') }
    window.addEventListener('keydown', onKey)
    window.addEventListener('mouseup', onMouse)
    return () => { window.removeEventListener('keydown', onKey); window.removeEventListener('mouseup', onMouse) }
  }, [])

  return (
    <div className={cx('app', collapsed && 'sidebar-collapsed')}>
      <Sidebar />
      <div className="main" inert={playerOpen}>
        <Toolbar />
        <div className="content" key={JSON.stringify(route.name === 'details' || route.name === 'anime-details' ? route.item.tmdbId : route.name)}>
          {route.name === 'home' && <HomePage />}
          {route.name === 'anime' && <AnimePage />}
          {route.name === 'favorites' && <FavoritesPage />}
          {route.name === 'details' && <DetailsPage item={route.item} />}
          {route.name === 'anime-details' && <AnimeDetailsPage item={route.item} />}
        </div>
      </div>
      {playerOpen ? <Player /> : <PartyDock />}
      <FollowPrompt />
      <StartPartyDialog />
      <ConnectDialog />
      <OfferDialog />
      <UpdateDialog />
      {joinOpen && <JoinPartyDialog onClose={() => useJoinDialog.setState({ open: false })} />}
      <ContextMenuHost />
      <Toast />
    </div>
  )
}
