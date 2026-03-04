const PLAYER_TOKEN_KEY = 'coeur.player-token'
const SESSION_CODE_KEY = 'coeur.session-code'

export function getOrCreatePlayerToken() {
  const current = window.localStorage.getItem(PLAYER_TOKEN_KEY)

  if (current) {
    return current
  }

  const created = crypto.randomUUID()
  window.localStorage.setItem(PLAYER_TOKEN_KEY, created)
  return created
}

export function readStoredSessionCode() {
  return window.localStorage.getItem(SESSION_CODE_KEY)
}

export function storeSessionCode(code: string) {
  window.localStorage.setItem(SESSION_CODE_KEY, code)
}

export function clearStoredSessionCode() {
  window.localStorage.removeItem(SESSION_CODE_KEY)
}
