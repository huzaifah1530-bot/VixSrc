// Small fetch helpers for scraping. Runs in the main process so we can set
// Referer / User-Agent headers the renderer is not allowed to send.

export const DESKTOP_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36'
export const MOBILE_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1'

export async function getResponse(url: string, headers: Record<string, string> = {}, timeoutMs = 12_000): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const res = await fetch(url, { headers, signal: controller.signal, redirect: 'follow' })
    if (res.status < 200 || res.status >= 400) throw new Error(`HTTP ${res.status}`)
    return res
  } finally {
    clearTimeout(timer)
  }
}

export async function getText(url: string, headers: Record<string, string> = {}, timeoutMs?: number): Promise<string> {
  return (await getResponse(url, headers, timeoutMs)).text()
}

export async function getJson<T = unknown>(url: string, headers: Record<string, string> = {}, timeoutMs?: number): Promise<T> {
  return JSON.parse(await getText(url, headers, timeoutMs)) as T
}

export function firstMatch(pattern: RegExp | string, text: string, group = 1): string | null {
  const re = typeof pattern === 'string' ? new RegExp(pattern, 'i') : pattern
  const m = re.exec(text)
  return m && m[group] !== undefined ? m[group] : null
}

export function allMatches(pattern: string, text: string): string[] {
  return Array.from(text.matchAll(new RegExp(pattern, 'gi')), m => m[0])
}
