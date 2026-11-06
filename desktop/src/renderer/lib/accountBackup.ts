export const revisionKey = (accountKey: string) => `vela_cloud_desktop_revision_${accountKey}`
export const hashKey = (accountKey: string) => `vela_cloud_desktop_hash_${accountKey}`

export async function backupHash(payload: Record<string, unknown>): Promise<string> {
  const stable = { ...payload }
  delete stable.exportedAt
  const bytes = new TextEncoder().encode(JSON.stringify(stable))
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('')
}
