import './styles/tokens.css'
import './styles/base.css'
import './styles/components.css'
import './styles/player.css'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { SettingsWindow } from './features/settings/SettingsWindow'

const isSettings = location.hash.replace('#', '') === 'settings'
createRoot(document.getElementById('root')!).render(isSettings ? <SettingsWindow /> : <App />)
