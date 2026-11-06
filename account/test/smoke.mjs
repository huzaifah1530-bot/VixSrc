import assert from 'node:assert/strict'

const root = process.env.VELA_ACCOUNT_TEST_URL ?? 'http://127.0.0.1:8789'
let username = `test_${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`

async function call(path, method, input, token) {
  const response = await fetch(`${root}/v1/${path}`, {
    method,
    headers: { 'content-type': 'application/json', 'X-Vela-Username': username, ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: input === undefined ? undefined : JSON.stringify(input)
  })
  return { status: response.status, data: await response.json() }
}

const registered = await call('register', 'POST', { username, pin: '9358' })
assert.equal(registered.status, 201, JSON.stringify(registered.data))
assert.equal(registered.data.recoveryCode.length, 32)
const firstToken = registered.data.token
assert.equal((await call('register', 'POST', { username, pin: '9358' })).status, 409)
assert.equal((await call('login', 'POST', { username, pin: '0012' })).status, 401)
const signedIn = await call('login', 'POST', { username, pin: '9358' })
assert.equal(signedIn.status, 200, JSON.stringify(signedIn.data))
assert.equal((await call('backup/ios', 'GET', undefined, firstToken)).status, 404)
const saved = await call('backup/ios', 'PUT', { baseRevision: 0, payload: { app: 'Vela', watchProgress: [] } }, firstToken)
assert.equal(saved.status, 200, JSON.stringify(saved.data))
assert.equal(saved.data.revision, 1)
assert.equal((await call('backup/ios', 'PUT', { baseRevision: 0, payload: {} }, firstToken)).status, 409)
const fetched = await call('backup/ios', 'GET', undefined, signedIn.data.token)
assert.equal(fetched.data.payload.app, 'Vela')
const recovered = await call('recover', 'POST', { username, recoveryCode: registered.data.recoveryCode, pin: '374839' })
assert.equal(recovered.status, 200, JSON.stringify(recovered.data))
assert.equal((await call('session', 'GET', undefined, firstToken)).status, 401)
assert.equal((await call('login', 'POST', { username, pin: '9358' })).status, 401)
assert.equal((await call('login', 'POST', { username, pin: '374839' })).status, 200)
const devices = await call('devices', 'GET', undefined, recovered.data.token)
assert.equal(devices.status, 200)
assert.equal(devices.data.devices.length, 2)
const changed = await call('username', 'POST', { next: `renamed_${username.slice(-10)}` }, recovered.data.token)
assert.equal(changed.status, 200, JSON.stringify(changed.data))
const olderDevice = await fetch(`${root}/v1/session`, { headers: { 'X-Vela-Username': username, 'X-Vela-Account-Key': registered.data.accountKey, authorization: `Bearer ${signedIn.data.token}` } })
assert.equal(olderDevice.status, 401) // recovery already revoked that session
username = changed.data.username
const renamedSession = await fetch(`${root}/v1/session`, { headers: { 'X-Vela-Username': 'stale_name', 'X-Vela-Account-Key': registered.data.accountKey, authorization: `Bearer ${recovered.data.token}` } })
assert.equal(renamedSession.status, 200)
assert.equal((await renamedSession.json()).username, username)
assert.equal((await call('pin', 'POST', { currentPin: '374839', newPin: '4892' }, recovered.data.token)).status, 200)
assert.equal((await call('login', 'POST', { username, pin: '4892' })).status, 200)
assert.equal((await call('session', 'DELETE', undefined, recovered.data.token)).status, 200)
assert.equal((await call('session', 'GET', undefined, recovered.data.token)).status, 401)
const finalLogin = await call('login', 'POST', { username, pin: '4892' })
assert.equal(finalLogin.status, 200)
assert.equal((await call('account', 'DELETE', { pin: '4892' }, finalLogin.data.token)).status, 200)
assert.equal((await call('session', 'GET', undefined, finalLogin.data.token)).status, 401)
const recreated = await call('register', 'POST', { username, pin: '532681' })
assert.equal(recreated.status, 201)
assert.equal((await call('account', 'DELETE', { pin: '532681' }, recreated.data.token)).status, 200)
console.log('account auth and backup smoke test passed')
