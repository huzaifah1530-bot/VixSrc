import { create } from 'zustand'
import type { MediaItem } from '@shared/types'

export type Route =
  | { name: 'home' }
  | { name: 'anime' }
  | { name: 'favorites' }
  | { name: 'details'; item: MediaItem }
  | { name: 'anime-details'; item: MediaItem }

interface NavState {
  stack: Route[]
  index: number
  route: Route
  push: (r: Route) => void
  root: (r: Route) => void
  back: () => void
  forward: () => void
}

export const useNav = create<NavState>((set, get) => ({
  stack: [{ name: 'home' }],
  index: 0,
  route: { name: 'home' },
  push: r => {
    const { stack, index } = get()
    const next = [...stack.slice(0, index + 1), r]
    set({ stack: next, index: next.length - 1, route: r })
  },
  root: r => set({ stack: [r], index: 0, route: r }),
  back: () => { const { stack, index } = get(); if (index > 0) set({ index: index - 1, route: stack[index - 1] }) },
  forward: () => { const { stack, index } = get(); if (index < stack.length - 1) set({ index: index + 1, route: stack[index + 1] }) }
}))

/** The toolbar search field; each section reads the query it cares about. */
interface SearchState { query: string; focusToken: number; setQuery: (q: string) => void; focus: () => void }
export const useSearch = create<SearchState>(set => ({
  query: '',
  focusToken: 0,
  setQuery: query => set({ query }),
  focus: () => set(s => ({ focusToken: s.focusToken + 1 }))
}))

interface ToastState { message: string | null; show: (m: string) => void }
let toastTimer: ReturnType<typeof setTimeout> | undefined
export const useToast = create<ToastState>(set => ({
  message: null,
  show: message => {
    clearTimeout(toastTimer)
    set({ message })
    toastTimer = setTimeout(() => set({ message: null }), 2200)
  }
}))
export const toast = (m: string) => useToast.getState().show(m)

/** Bumped by Ctrl+R / the refresh button. */
export const useRefresh = create<{ token: number; bump: () => void }>(set => ({ token: 0, bump: () => set(s => ({ token: s.token + 1 })) }))
