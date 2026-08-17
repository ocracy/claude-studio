// Web Push: how the phone hears that a session finished while it is in a pocket.
//
// Implemented directly against the specs rather than through a library, so the
// bridge stays dependency-free like the rest of it:
//
//   RFC 8291 — message encryption (aes128gcm)
//   RFC 8292 — VAPID, the signed claim that identifies this sender
//
// Node's crypto has every primitive these need, including P-256 ECDH, HKDF and
// JOSE-format ECDSA signatures, so nothing here is hand-rolled cryptography —
// it is assembly of standard pieces in the order the specs prescribe.

import { createHmac, createCipheriv, createECDH, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign as signWith } from "node:crypto"
import { readFileSync } from "node:fs"
import { request as httpsRequest } from "node:https"
import { join } from "node:path"

import { appSupport, writeAtomically } from "./paths.mjs"

const vapidFile = join(appSupport, "vapid.json")
const subscriptionsFile = join(appSupport, "push-subscriptions.json")

// Push services want a way to contact the sender. Nothing is sent to it and no
// personal address belongs in a file that ships with the repo.
const SUBJECT = "mailto:noreply@claude-studio.local"

const b64url = (buffer) => Buffer.from(buffer).toString("base64url")

// ── identity ─────────────────────────────────────────────────────────────

/**
 * The sender's long-lived P-256 key pair. Created on first use and kept: the
 * public half is baked into every subscription the phone makes, so replacing it
 * silently invalidates them all.
 */
export function vapidKeys() {
  try {
    return JSON.parse(readFileSync(vapidFile, "utf8"))
  } catch {
    const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
    const keys = {
      // Uncompressed point (0x04 || X || Y) — the form applicationServerKey wants.
      publicKey: b64url(publicKey.export({ type: "spki", format: "der" }).subarray(-65)),
      privateKey: privateKey.export({ type: "pkcs8", format: "pem" }),
    }
    writeAtomically(vapidFile, JSON.stringify(keys, null, 2))
    return keys
  }
}

/** VAPID header pair: a short-lived JWT plus the public key that verifies it. */
function authorization(endpoint) {
  const { publicKey, privateKey } = vapidKeys()
  const audience = new URL(endpoint).origin

  const header = b64url(JSON.stringify({ typ: "JWT", alg: "ES256" }))
  const claims = b64url(JSON.stringify({
    aud: audience,
    exp: Math.floor(Date.now() / 1000) + 12 * 60 * 60,
    sub: SUBJECT,
  }))

  // JOSE wants the raw r||s pair; Node emits DER unless asked otherwise.
  const signature = signWith("sha256", Buffer.from(`${header}.${claims}`), {
    key: createPrivateKey(privateKey),
    dsaEncoding: "ieee-p1363",
  })

  return `vapid t=${header}.${claims}.${b64url(signature)}, k=${publicKey}`
}

// ── encryption (RFC 8291) ────────────────────────────────────────────────

const hmac = (key, data) => createHmac("sha256", key).update(data).digest()

/** HKDF with a single-block expand, which is all these lengths need. */
function derive(salt, ikm, info, length) {
  return hmac(hmac(salt, ikm), Buffer.concat([info, Buffer.from([1])])).subarray(0, length)
}

/**
 * Encrypt `plaintext` for one subscription.
 *
 * The body is `salt | record size | key id length | sender public key |
 * ciphertext`, and the receiving browser reverses it with the private half of
 * the keys it handed out when it subscribed.
 */
export function encrypt(plaintext, subscription) {
  const uaPublic = Buffer.from(subscription.keys.p256dh, "base64url")
  const authSecret = Buffer.from(subscription.keys.auth, "base64url")

  const ecdh = createECDH("prime256v1")
  ecdh.generateKeys()
  const senderPublic = ecdh.getPublicKey()
  const shared = ecdh.computeSecret(uaPublic)

  const salt = randomBytes(16)

  // The key derivation is bound to both public keys, so a message can only be
  // read by the subscription it was built for.
  const keyInfo = Buffer.concat([
    Buffer.from("WebPush: info\0"), uaPublic, senderPublic,
  ])
  const ikm = hmac(hmac(authSecret, shared), Buffer.concat([keyInfo, Buffer.from([1])]))

  const key = derive(salt, ikm, Buffer.from("Content-Encoding: aes128gcm\0"), 16)
  const nonce = derive(salt, ikm, Buffer.from("Content-Encoding: nonce\0"), 12)

  // 0x02 marks the last record; there is only ever one here.
  const padded = Buffer.concat([Buffer.from(plaintext, "utf8"), Buffer.from([2])])
  const cipher = createCipheriv("aes-128-gcm", key, nonce)
  const ciphertext = Buffer.concat([cipher.update(padded), cipher.final(), cipher.getAuthTag()])

  const recordSize = Buffer.alloc(4)
  recordSize.writeUInt32BE(4096)

  return Buffer.concat([
    salt, recordSize, Buffer.from([senderPublic.length]), senderPublic, ciphertext,
  ])
}

// ── subscriptions ────────────────────────────────────────────────────────

export function readSubscriptions() {
  try {
    const parsed = JSON.parse(readFileSync(subscriptionsFile, "utf8"))
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

function writeSubscriptions(list) {
  writeAtomically(subscriptionsFile, JSON.stringify(list, null, 2))
}

/** Register a device, or update the preferences of one already known. */
export function saveSubscription(subscription, preferences = {}) {
  const list = readSubscriptions().filter((s) => s.endpoint !== subscription.endpoint)
  list.push({ ...subscription, preferences, addedAt: Date.now() })
  writeSubscriptions(list)
}

export function removeSubscription(endpoint) {
  writeSubscriptions(readSubscriptions().filter((s) => s.endpoint !== endpoint))
}

export function updatePreferences(endpoint, preferences) {
  const list = readSubscriptions().map((s) =>
    s.endpoint === endpoint ? { ...s, preferences: { ...s.preferences, ...preferences } } : s)
  writeSubscriptions(list)
}

// ── delivery ─────────────────────────────────────────────────────────────

function deliver(subscription, body) {
  return new Promise((resolve) => {
    const endpoint = new URL(subscription.endpoint)
    const payload = encrypt(JSON.stringify(body), subscription)

    const req = httpsRequest({
      hostname: endpoint.hostname,
      path: endpoint.pathname + endpoint.search,
      method: "POST",
      headers: {
        authorization: authorization(subscription.endpoint),
        "content-encoding": "aes128gcm",
        "content-type": "application/octet-stream",
        "content-length": payload.length,
        ttl: 86400,
        urgency: "normal",
      },
    }, (res) => {
      res.resume()
      // 404/410 mean the browser threw the subscription away — stop keeping it.
      if (res.statusCode === 404 || res.statusCode === 410) {
        removeSubscription(subscription.endpoint)
      }
      resolve(res.statusCode)
    })

    req.on("error", (error) => {
      console.error(`cs-bridge: push failed: ${error.message}`)
      resolve(0)
    })
    req.end(payload)
  })
}

/**
 * Notify every device that asked to hear about this project.
 * @param {{title: string, body: string, tmux?: string, project?: string}} message
 */
export async function notify(message) {
  const results = await Promise.all(
    readSubscriptions()
      .filter((subscription) => wants(subscription, message))
      // Alert preferences are per device — one phone can be set to buzz
      // silently while another rings — so they ride along in each payload
      // rather than being baked into the message.
      .map((subscription) =>
        deliver(subscription, { ...message, silent: Boolean(subscription.preferences?.silent) })),
  )
  return results.filter((status) => status >= 200 && status < 300).length
}

function wants(subscription, message) {
  const preferences = subscription.preferences ?? {}
  if (preferences.enabled === false) return false
  // An empty list means every project; the phone only sends one once the user
  // narrows it down.
  const projects = preferences.projects
  if (Array.isArray(projects) && projects.length && message.project) {
    return projects.includes(message.project)
  }
  return true
}
