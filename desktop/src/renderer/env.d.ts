/// <reference types="vite/client" />
import type { VelaApi } from '@shared/types'

declare global {
  interface Window { vela: VelaApi }
}

declare module 'react' {
  namespace JSX {
    interface IntrinsicElements {
      webview: React.DetailedHTMLProps<React.HTMLAttributes<HTMLElement>, HTMLElement> & {
        src?: string
        partition?: string
        allowpopups?: string
        webpreferences?: string
      }
    }
  }
}

export {}
