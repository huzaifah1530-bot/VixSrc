export interface AccountReply { status: number; data: Record<string, any> }
export interface AccountApi {
  status(): Promise<{ username: string | null }>
  call(action: string, body?: Record<string, unknown>): Promise<AccountReply>
}
