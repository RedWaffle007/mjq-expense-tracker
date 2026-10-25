# Construction Expense Tracker — Project Plan

## Instructions for Claude Code

1. Read this entire document before writing any code.
2. Review the plan and raise any gaps, risks, or better alternatives. Ask clarifying questions before starting.
3. Verify that all package versions, Firebase APIs, Cloudflare/Cloudinary APIs, and Gemini model names are current at the time of building. Do not rely on versions from memory.
4. Work milestone by milestone (see "Build Milestones"). Finish and verify each milestone's acceptance criteria before moving on.
5. Use the Firebase Emulator Suite (Auth + Firestore) for local development and testing, and `wrangler dev` for the Worker. Write unit tests for security rules and for the Worker.
6. Keep the app simple. The goal is to solve one problem well. Do not add features outside this document without asking.
7. **Everything must run on free tiers with no billing account or payment card anywhere**: Firebase Spark plan, Cloudflare Workers Free, Cloudinary Free, Gemini Developer API free tier. Never introduce a service or feature that needs Blaze or a card. See Section 15.

---

## 1. Problem and Goal

The CEO of a construction company finds it hard to manually keep track of all expenses across multiple building sites.

**Goal:** make it effortless for site managers to record every expense (by voice or by hand, with a bill photo) and give the CEO a clear, always-up-to-date view of where the money went, with an Excel export at any time.

Scope is deliberately narrow: **expense tracking only.** Budgets, vendor dues, labour attendance, cash advances, and analytics are out of scope for v1 (see Section 12).

## 2. Users and Roles

| Role | Count at launch | Permissions |
|---|---|---|
| CEO | 1 | Everything managers can do, plus: invite users, add/edit/archive sites, download Excel exports |
| Manager | 2 (more later) | Add, edit, and soft-delete expenses on any site; view all sites, entries, history, and activity |

- Currently 3 construction sites, shared by 2 managers. Every user can see every site.
- The CEO can add more managers and sites at any time.
- Users sign in with their Google account. Only email addresses invited by the CEO can access the app.
- The CEO records both the user's Google email and mobile number. The app creates the email-bound invite, then opens a pre-filled SMS containing an opaque invitation link; the CEO taps Send. The link never authenticates the recipient by itself.

## 3. Features

### 3.1 Accounts and Sites
- CEO invites a user by entering name, Google account email, mobile number, and role.
- The invitation is delivered through the CEO's normal SMS app, avoiding a paid SMS gateway. If the app is installed, the verified link opens it; otherwise it opens an APK installation page. After installation, the user signs in with the invited Google account.
- Invited user signs in with Google and is automatically assigned their role.
- Managers are permanent once added; the app does not expose a remove/deactivate control. The server-side emergency deactivation safeguard remains available only for maintenance or a compromised account.
- CEO can add a site (name, location/address, optional notes) and archive a completed site.
- Each site has its own tab/screen with its own running totals.

### 3.2 Adding an Expense
Each expense entry has:

| Field | Required | Notes |
|---|---|---|
| Site | Yes | Pre-selected if adding from inside a site tab |
| Item | Yes | e.g. "Cement (OPC 53)" |
| Category | Yes | Material, Labour, Equipment, Transport, Other |
| Amount (₹) | Yes | Total amount paid |
| Quantity | No | Free text, e.g. "50 bags", "2.5 ton", "1 load". If it starts with a number, amount = that number × price per item; otherwise the price per item is the amount |
| Unit | No | bags, kg, ton, cft, sqft, nos, trips, days, litre, other |
| Rate | No | Per-unit price. If quantity and rate are both entered, amount auto-fills as qty × rate but stays editable |
| Vendor | No | Free text |
| Expense date | Yes | Defaults to today; can be changed for back-dated entries |
| Note | No | Free text |
| Bill photos | No | One or more photos |

**Voice entry**
- Manager taps a mic button and speaks naturally, e.g. "50 bags cement, 380 each, from Sai Traders."
- The recording is sent to Gemini (via Firebase AI Logic, Gemini Developer API free tier), which returns structured JSON for the fields above.
- The app shows a pre-filled form. The manager reviews, edits if needed, attaches a bill photo, and taps Save.
- Nothing is saved without the manager's confirmation.
- Must handle English, Hindi, and mixed Hindi-English speech, and Indian number words ("1 lakh", "1.5 lakh", "20 hazaar", "twenty thousand").
- If something is unclear (e.g. no amount spoken), leave that field empty and highlight it rather than guessing.
- Audio recordings are **not** stored after parsing.
- **Voice entry always works.** Gemini is the primary parser. When Gemini is unavailable (offline, error, timeout, or daily quota used up), the app automatically falls back to **on-device speech recognition** plus an on-device parser (Section 8). The form shows a small "Parsed on device — please check" label in that case.
- The on-device fallback works offline only if the phone has the offline speech pack for the language installed; onboarding prompts users to download the English and Hindi packs. If no recognizer is available at all, the mic shows "Voice isn't available right now — use manual entry."
- Free-tier Gemini data use is accepted (Decision 6, Section 13).

**Manual entry**
- Same form as voice, filled by hand. Always available, including offline.

**Bill photos**
- Take a photo with the camera or pick from the gallery.
- Compress before upload (target roughly under 500 KB, long edge around 1600 px, still readable).
- Stored on **Cloudinary** (free plan) as private, authenticated assets. Uploads are signed by the Worker; photos are viewed through Worker-signed URLs. Unsigned URLs do not work.
- Anyone signed in can tap a thumbnail to view the full photo.

### 3.3 Offline Mode
- Sites often have poor signal. The app must work fully offline for adding, editing, and viewing cached data.
- Entries saved offline are stored locally and sync automatically when the connection returns (Firestore offline persistence). The history and activity docs are part of the same batch, so they sync with the entry.
- Bill photos taken offline are saved to app storage and placed in a persistent local upload queue. The queue survives app restarts and uploads to Cloudinary automatically when online, then links the photo to its entry.
- UI shows a clear indicator on entries or photos still waiting to sync, and a global "X items waiting to sync" banner.
- Entries use client-generated IDs so offline creation works.
- **Offline edit conflicts: last write wins** (Decision 7). If someone edits an entry while another user's offline edit of the same entry is waiting to sync, the later-synced edit is applied field by field (only the fields that user changed are written). Edit history keeps both versions: the other user's change has its own history record, and the offline edit's record is marked as a conflict and names the change it overwrote. The entry shows a small note: "Edited by someone else while you were offline." The note clears on the next normal edit.
- An offline edit to an entry that was deleted in the meantime still applies, but the entry stays deleted. An offline delete of an entry edited in the meantime still deletes it. Both cases show the same note in history.
- Any other write the server rejects (e.g. the user was deactivated) is shown in the sync banner, not dropped silently.

### 3.4 Editing, Deleting, and Edit History
- Any saved entry can be edited at any time by any manager or the CEO.
- Deleting is a **soft delete**: the entry is hidden from lists and totals but kept in the database.
- **Edit history:** every create, edit, and delete records who did it, when, and the before/after values of changed fields.
- History is written **by the app, in the same batched write as the entry change**. Security rules reject any entry create/update/soft-delete that doesn't come with a matching history doc (checked with `getAfter`/`existsAfter`, including the before/after values). History docs are create-only: they can never be updated or deleted from the app.
- Each entry detail screen shows its full history, e.g. "Amount ₹1,00,000 → ₹1,20,000 · edited by Ravi · 12 Oct, 4:32 PM."

### 3.5 Notifications
- Every create, edit, or delete by any user sends a push notification to **all other active users** (not the person who did it).
- Pushes are sent by the Cloudflare Worker (Section 6) using FCM HTTP v1.
- Notifications include the details, for example:
  - "Ravi added Cement (50 bags) · ₹19,000 · Site 2"
  - "Suresh edited Steel at Site 1: Amount ₹1,00,000 → ₹1,20,000"
  - "Ravi deleted Sand · ₹8,500 · Site 3"
- Tapping a notification opens that entry.
- **Activity feed:** an in-app screen listing every action across all sites, newest first. This is the source of truth if a phone blocks a notification. Activity docs are written by the app in the same batch as the entry change and are create-only, like history.
- Reliability requirements:
  - Send as high-priority FCM messages on a dedicated high-importance Android notification channel.
  - After a write syncs, the app asks the Worker to send the push right away. A Worker cron job also sweeps for activity that was never pushed (e.g. the phone went offline or was closed right after syncing), so no notification is lost.
  - During onboarding, guide users to disable battery optimization and enable autostart (important on Xiaomi, Oppo, Vivo, Realme, and similar phones). Show brand-specific instructions where possible.
  - Refresh and store FCM tokens on every app start; the Worker removes invalid tokens.
  - Request notification permission on Android 13+ and iOS.

### 3.6 Viewing the Numbers
- **Site screen:** total spent, breakdown by category, and a searchable, filterable list of entries (filter by category, date range, and who entered it).
- **Overview screen:** all active sites side by side with their totals, plus a grand total that stays collapsed until tapped.
- All amounts shown in Indian number format (₹1,00,000).
- Totals are computed **in the app** (there are no server-side aggregates). See "Site totals" under Section 5.

### 3.7 Excel Export (CEO only)
- CEO taps "Download Excel" at any time. Managers never see this option.
- The workbook is **generated on the CEO's phone** (Dart Excel package), from a fresh read of all entries.
- Generates one workbook containing:
  - **One sheet per site**, listing every (non-deleted) entry with columns: Date, Item, Category, Quantity, Unit, Rate, Amount (₹), Vendor, Note, Entered by, Entered at, Last edited by, Last edited at, Bill photo link(s), Entry ID.
  - Each site sheet ends with a total row and a small category subtotal table.
  - **Final sheet "All Sites"**: every entry from all sites with a Site column added, followed by a summary table of totals per site, per category, and a grand total.
- Amount columns formatted as Indian Rupees; header row frozen; column widths set for readability.
- Bill photo links are signed Cloudinary URLs requested from the Worker at export time. They don't expire, so anyone with the file can open the photos (Decision 1).
- Saving an export records `lastExportAt` in `config/app`.
- File name: `Expenses_<YYYY-MM-DD_HHmm>.xlsx`.
- The app saves the file and offers Open / Share.
- Export requires internet (it needs up-to-date data and photo links).

### 3.8 Security Basics
- Google sign-in, limited to invited emails.
- App lock with fingerprint/face or device PIN, required when the app opens after being in the background for more than a few minutes.
- App Check (Play Integrity) on Firestore, Firebase AI Logic, and Worker requests.
- **Backups:** the Spark plan has no scheduled Firestore backups. The CEO's **weekly Excel export is the backup**. It covers every non-deleted entry plus photo links, but not edit history, the activity feed, or deleted entries. Photos themselves stay on Cloudinary. This limitation is accepted (Decision 9). The CEO sees a reminder banner on the Overview screen when the last export is more than 7 days old (`config/app.lastExportAt`).

## 4. Tech Stack

| Layer | Choice |
|---|---|
| Mobile app | Flutter (Android first; iOS supported) |
| Language | Dart (app), TypeScript (Worker) |
| Firebase plan | **Spark (no-cost)**. No billing account is linked, ever. |
| Auth | Firebase Authentication with Google sign-in; custom claims for roles (set by the Worker) |
| Database | Cloud Firestore, region **asia-south1 (Mumbai)**, offline persistence enabled |
| Server logic | **Cloudflare Worker** (Workers Free plan, no card). Firestore REST API, FCM HTTP v1, and Identity Toolkit REST API, authenticated with a Firebase service account stored as a Worker secret. |
| Bill photo storage | **Cloudinary** (Free plan, no card). Private "authenticated" assets, signed uploads, signed delivery URLs. |
| Push notifications | Firebase Cloud Messaging (client) + flutter_local_notifications; sent by the Worker |
| Voice-to-entry | Firebase AI Logic with the **Gemini Developer API free tier**, using a current Flash model that supports free audio input (multimodal audio, structured JSON output) |
| App integrity | Firebase App Check (Play Integrity on Android, App Attest on iOS); the Worker verifies App Check tokens too |
| Excel generation | On device, Dart Excel package |
| Backups | CEO's weekly Excel export (no scheduled backups on Spark) |

**Important:** the Firestore database location cannot be changed after creation. Create it in asia-south1.

**Not used (need Blaze):** Cloud Functions, Cloud Storage for Firebase, scheduled Firestore backups, point-in-time recovery.

### 4.1 Suggested Packages
Verify each is current and maintained before use.

**Flutter app**
- Firebase: `firebase_core`, `firebase_auth`, `cloud_firestore`, `firebase_messaging`, `firebase_app_check`, `firebase_ai`
- Sign-in: `google_sign_in`
- Worker calls: `http`
- Notifications: `flutter_local_notifications`
- State management: `flutter_riverpod`
- Routing: `go_router`
- Audio recording: `record`
- On-device speech fallback: `speech_to_text`
- Camera/gallery: `image_picker`
- Image compression: `flutter_image_compress`
- Local upload queue: `drift` (or `hive`) for the persistent photo queue and pending-edit tracking
- Connectivity and background retry: `connectivity_plus`, `workmanager`
- App lock: `local_auth`
- Formatting: `intl` (Indian locale, `en_IN`)
- Excel: `excel`, if a spike confirms it supports frozen panes, rupee number formats, column widths, and hyperlinks. Otherwise another maintained pure-Dart library with a license that permits commercial use (Decision 8).
- Files: `path_provider`, `open_filex`, `share_plus`
- Images: `cached_network_image`

**Worker**
- `wrangler` (deploy and local dev), TypeScript, a test runner (e.g. `vitest`)
- WebCrypto only, no heavy SDKs (Firebase Admin SDK does not run in Workers; the free plan has a 10 ms CPU limit)

**Rules tests**
- `@firebase/rules-unit-testing`, `firebase-tools` (emulators)

## 5. Data Model (Firestore)

All money is stored as **integers in paise** (₹1,00,000 = `10000000`) to avoid rounding errors. All timestamps are Firestore server timestamps where possible.

### `users/{uid}` (written by the Worker only; `fcmTokens` also by the user for their own doc)
```
name: string
email: string            // lowercased Google account email
role: "ceo" | "manager"
active: boolean
fcmTokens: string[]
createdAt: timestamp
```

### `invites/{emailLowercase}` (Worker only)
```
name: string
email: string
phone: string            // E.164; addresses the pre-filled SMS invitation
inviteToken: string      // opaque, revocable link token; never grants app access
role: "ceo" | "manager"
invitedBy: uid
createdAt: timestamp
claimed: boolean
claimedBy: uid | null
```

### `sites/{siteId}`
```
name: string
location: string
notes: string
status: "active" | "archived"
createdBy: uid
createdAt: timestamp
```
(No stored aggregates. Totals are computed in the app; see "Site totals" below.)

### `entries/{entryId}`
Top-level collection (makes cross-site queries and export simple).
```
siteId: string
item: string
category: "material" | "labour" | "equipment" | "transport" | "other"
amount: int (paise)
quantity: string | null    // free text, 1–60 chars; entries saved before 2026-10-25 may hold a positive number
unit: string | null
rate: int (paise) | null
vendor: string | null
note: string | null
expenseDate: timestamp
photos: [{ publicId: string, uploadedAt: timestamp }]   // Cloudinary public ID
pendingPhotoCount: int     // photos still in the local upload queue
source: "voice" | "manual"
createdBy: uid
createdAt: timestamp
updatedBy: uid
updatedAt: timestamp
isDeleted: boolean
deletedBy: uid | null
deletedAt: timestamp | null
lastChangeId: string       // ID of the history + activity docs written in the same batch
baseChangeId: string | null   // the lastChangeId this edit was based on (null on create)
conflict: { by: uid, at: timestamp } | null   // set when this write overwrote a concurrent change; drives the "edited by someone else while you were offline" note
```
Edits are written as partial updates of only the fields the user changed, so a concurrent edit to other fields is kept.

### `entries/{entryId}/history/{changeId}` (app-written in the same batch, create-only)
```
action: "create" | "update" | "delete"
by: uid
at: timestamp              // must equal request.time
changes: { fieldName: { before: any, after: any } }
conflict: boolean          // true when the edit was based on an older version (last write wins)
overwroteChangeId: string | null   // the server's lastChangeId at write time, when conflict is true
```
In a conflict, `before` holds the values the editor saw (their base version). The overwritten values are in the history record of `overwroteChangeId`, so both versions are kept.
For `create`, `before` is null for every field. `changes` covers every user-visible field that changed: siteId, item, category, amount, quantity, unit, rate, vendor, note, expenseDate, photos. Bookkeeping fields (`updatedBy`, `updatedAt`, `pendingPhotoCount`, `lastChangeId`, `baseChangeId`, `conflict`, delete fields) are not listed.

### `activity/{changeId}` (app-written in the same batch, create-only for clients)
```
type: "create" | "update" | "delete"
photoOnly: boolean     // true when the only change was attaching photos (Open Decision 3)
entryId: string
siteId: string
actorId: uid
summary: string        // human-readable, same text as the notification
createdAt: timestamp   // must equal request.time
notifiedAt: timestamp | null   // null on create; set only by the Worker after sending the push
```

### `config/app`
```
categories: [...]       // allows adding categories later without an app update
units: [...]
lastExportAt: timestamp | null   // set by the CEO's device after each export; drives the backup reminder
```

### Indexes
- `entries`: `siteId` + `isDeleted` + `expenseDate desc`
- `entries`: `siteId` + `isDeleted` + `category` + `expenseDate desc`
- `activity`: `createdAt desc`
- `activity`: `notifiedAt` + `createdAt` (for the Worker's sweep)

### Site totals (computed in the app)
- **Online:** Firestore aggregation queries (`sum('amount')` and `count()` on non-deleted entries, per site and per category). These are billed by index entries read, far cheaper than reading every entry.
- **Offline:** show the last known totals (saved locally after every online fetch), adjusted by this phone's unsynced changes, with an "as of <time>" label.
- **Unsynced changes:** every entry write records its site/category amount change locally until Firestore acknowledges or rejects it, and totals add these on top of the server or last-known figure, so a new, edited, or deleted expense shows in the totals immediately, online or offline.
- **Refresh:** totals are fetched again whenever a new activity doc appears (any user's change) or a local change settles, using a one-document listener on the newest activity.
- Do **not** keep a live listener on every entry for totals. A listener that reconnects after more than 30 minutes is billed as a brand-new query, which would exceed the 50K reads/day limit as entries grow. Entry lists are paginated (e.g. 50 at a time).

## 6. Cloudflare Worker (server)

One Worker on the Cloudflare Workers Free plan, written in TypeScript. It replaces Cloud Functions.

**Secrets (via `wrangler secret put`, never in git):** Firebase service-account JSON, Cloudinary API secret.
**Vars:** Firebase project ID, Cloudinary cloud name and API key.

**Every request:** POST only, JSON body with a size cap, `Authorization: Bearer <Firebase ID token>`. The Worker verifies the token (RS256 signature against Google's public keys, `aud`/`iss` for this project, expiry). From Milestone 6 it also verifies the `X-Firebase-AppCheck` token. It fails closed. Except for `/signup/complete`, the caller must have `active == true` in `users/{uid}`, and CEO-only routes also require `role == "ceo"` there. The Worker checks the doc, not just the claims, so deactivation takes effect immediately.

Service-account OAuth access tokens are cached in memory between requests (they last an hour), so each request stays within the 10 ms CPU limit.

| Endpoint | Who | Purpose |
|---|---|---|
| `POST /signup/complete` | Any Google-signed-in user | Read the verified `email` from the ID token (`email_verified` must be true; never trust an email in the request body). Look up `invites/{email}`; reject with 403 if missing or already claimed by another uid. Create `users/{uid}`, set custom claims `{ role, active: true }` via Identity Toolkit `accounts:update`, and mark the invite claimed. The app then force-refreshes its ID token. |
| `POST /invites/create` | CEO | Create `invites/{email}` (name, email, phone, role, opaque invite token) and return its HTTPS invitation link. |
| `POST /users/set-active` | CEO | Activate or deactivate a user. Update `users/{uid}.active` and the claims. On deactivation, also set `disableUser: true` and `validSince: now` (revokes sessions). The CEO cannot deactivate themselves. |
| `POST /notify` | Active user | Body `{ activityId }`. Load the activity doc and check that `actorId` is the caller and `notifiedAt` is null. Send a high-priority FCM message to every active user except the actor, remove tokens FCM reports as invalid, and set `notifiedAt`. |
| `POST /photos/sign-upload` | Active user | Body `{ siteId, entryId }`. Return a Cloudinary upload signature for `type: authenticated`, a public ID scoped to `bills/{siteId}/{entryId}/{random}`, image formats only, and a timestamp. |
| `POST /photos/view-urls` | Active user | Body `{ publicIds[], variant: "thumb" | "full" }`. Return signed delivery URLs, capped at a few dozen IDs per call. Also used by the Excel export. |
| Cron (every 2 minutes) | — | Sweep `activity` where `notifiedAt == null` and `createdAt` is older than 1 minute, and send those pushes (same logic as `/notify`, idempotent via `notifiedAt`). |

**Notes**
- `/notify` and the cron sweep must be idempotent. Set `notifiedAt` with a Firestore precondition (update time) so two runs can't both send.
- Entries created offline reach Firestore when the phone reconnects. Pushes then happen through the app's `/notify` call or the cron sweep. Use `createdAt`/`updatedAt` from the entry for display.
- Photo-only updates (the upload queue attaching a photo later) have `photoOnly: true`. Per Open Decision 3, either send a gentler push ("Ravi added a bill photo to Cement · Site 2") or skip the push and log activity only.
- **CEO bootstrap:** a one-off local Node script (`/worker/scripts/bootstrap-ceo.mjs`) writes `invites/{ceoEmail}` with role `ceo`, using the service account. The CEO then signs up through the normal flow.
- **Local dev:** the Worker's Firestore and Identity Toolkit transports can point at the emulators. Emulator ID tokens are unsigned, so accept them only when an explicit `EMULATOR=true` var is set, and never in production.

## 7. Security Rules and Access Control

### Firestore (outline)
- `isActive()`: `request.auth != null` **and** custom claim `active == true` **and** `get(users/{uid}).data.active == true`. Checking the doc makes deactivation immediate even while an old ID token is still valid.
- `isCeo()`: `isActive()` and `get(users/{uid}).data.role == "ceo"`.
- `users`: read by active users. Clients may only update `fcmTokens` on their own doc. All other writes are denied (Worker only).
- `invites`: read by CEO; writes denied from clients (Worker only).
- `sites`: read by active users; create/update only if `isCeo()`; delete denied.
- `entries`:
  - read by active users
  - create: `createdBy == request.auth.uid`, `amount` is an int > 0, `siteId` refers to an active site, `isDeleted == false`, required fields present and correctly typed, `createdAt == updatedAt == request.time`, **and** `existsAfter(history/{lastChangeId})` and `existsAfter(activity/{lastChangeId})` with matching contents (below).
  - update: allowed for active users; `createdBy` and `createdAt` cannot change; `siteId` change per Open Decision 2; `updatedBy == request.auth.uid`, `updatedAt == request.time`; `amount` stays a positive int; `lastChangeId` must change to a new ID whose history doc did not exist before (`!exists(...)`) and does exist after (`existsAfter(...)`).
  - soft delete is an update setting `isDeleted: true`, `deletedBy == uid`, `deletedAt == request.time`. Un-deleting (true → false) is denied.
  - hard delete denied.
  - **History match:** `getAfter(history/{lastChangeId})` must have `by == uid` and `at == request.time`. Its `action` must be `create` on create, `delete` when the write sets `isDeleted` to true, and `update` otherwise. The tracked fields are a fixed list, so these checks are written out field by field (rules have no loops):
    - **Normal edit** (`baseChangeId == resource.data.lastChangeId`): history `conflict == false`, entry `conflict == null`. A field appears in `changes` exactly when it changed (`request.resource.data.diff(resource.data).affectedKeys()`), with `changes[f].before == resource.data[f]` and `changes[f].after == request.resource.data[f]`.
    - **Conflicting edit** (`baseChangeId != resource.data.lastChangeId`, last write wins): history `conflict == true` and `overwroteChangeId == resource.data.lastChangeId`; entry `conflict == { by: uid, at: request.time }`. Every tracked field that changed must be in `changes`, and every field in `changes` must have `after == request.resource.data[f]`. `before` is the editor's base version, which the server can't verify; that's acceptable because the overwritten values are already in the previous history record.
    - `isDeleted` can go false → true, never back. A conflicting edit leaves `isDeleted` untouched, so an entry deleted in the meantime stays deleted.
  - **Activity match:** `getAfter(activity/{lastChangeId})` must have the same `type`, `entryId`, `siteId`, `actorId == uid`, `createdAt == request.time`, and `notifiedAt == null`.
- `entries/{id}/history/{changeId}`: read by active users. Create only if `getAfter(entries/{id}).data.lastChangeId == changeId` and `by == uid`. Update/delete denied.
- `activity/{changeId}`: read by active users. Create only if `getAfter(entries/{entryId}).data.lastChangeId == changeId` and `actorId == uid`. Client update/delete denied (the Worker sets `notifiedAt` with the service account).
- `config`: read by active users; write CEO only.
- Budget: an entry write uses roughly 4–6 `get`/`exists` calls across the batch, well under the limit of 20 per batch (10 per operation).

### Bill photos (Cloudinary)
- Assets are uploaded as `type: authenticated`, so they can't be viewed without a signed URL.
- Only the Worker holds the API secret. It signs uploads only for active users and only under `bills/{siteId}/{entryId}/`.
- The app never deletes photos; there is no delete endpoint.

### Worker
- Covered in Section 6: verified ID token on every call, role and active checks from `users/{uid}`, App Check from Milestone 6, fail closed.

Write rules unit tests with the emulator covering: uninvited user blocked, deactivated user blocked (even with an old token that still carries `active: true`), manager cannot manage users or sites, clients cannot write invites, other users' docs, `notifiedAt`, or history/activity except in a matching batch, entry write without a matching history doc rejected, history with wrong before/after values rejected on a normal edit, conflicting edit accepted only with `conflict`/`overwroteChangeId` set correctly, un-delete rejected, history/activity cannot be updated or deleted, hard delete denied, invalid amounts rejected.

Write Worker tests covering: missing/invalid/expired token rejected, uninvited email rejected at signup, email in the body ignored, manager blocked from CEO routes, deactivated user blocked, `/notify` excludes the actor and is idempotent, invalid FCM tokens removed, upload signatures scoped to the right folder.

## 8. Voice Entry Flow (Detail)

1. User taps mic → record audio (AAC/m4a, mono, modest bitrate) with a visible timer; max ~60 seconds.
2. On stop, send audio to Gemini through Firebase AI Logic (Gemini Developer API, free tier) with:
   - A system prompt describing the task, the Indian context (lakh/crore/hazaar, common construction items and units, Hindi-English mixing), and the rules: extract only what was said, never invent values, return null for missing fields.
   - A JSON response schema matching the entry fields (item, category, quantity, unit, rate, amount, vendor, note), with amounts returned in rupees as numbers.
3. Validate the response in the app; convert rupees to paise.
4. Show the pre-filled form with unfilled required fields highlighted.
5. If qty and rate are present but amount is missing, compute it; if all three are present but don't match, keep the spoken amount and show a small warning.
6. User edits if needed, adds photo, saves. `source = "voice"`.
7. Discard the audio file.
8. If the free-tier daily quota is used up, the app remembers this until the quota resets (midnight Pacific time) and goes straight to the on-device path.

**On-device fallback (automatic):**
- **Choosing the path before recording:** if the phone is offline, or Gemini returned a quota error earlier today, the mic starts in on-device mode immediately. Otherwise it records audio for Gemini.
- **Gemini fails after recording** (error, timeout of ~15 s, quota): the recorded audio can't be fed to the on-device recognizer, so the app discards it, says "Couldn't reach Gemini — speak again", and starts on-device listening straight away with one tap.
- **On-device path:** live recognition with Android's recognizer via `speech_to_text` (prefer offline recognition; locale en-IN or hi-IN, user can switch). The transcript goes to an on-device parser that extracts amount, quantity, unit, rate, vendor, and category from keywords, handling Indian number words (lakh, crore, hazaar, English and Hindi numerals). The item defaults to the leftover words.
- The parsed result fills the same form with the same rules: unclear fields left empty and highlighted, nothing saved without confirmation. `source = "voice"` either way.
- Nothing is sent off the phone on this path.
- Based on time-app's `speech_service.dart` / `platform_speech_service.dart` (recognizer wrapper). The parser is new, with its own unit tests.

Pick a current Flash model whose **free tier includes audio input** (check the Gemini pricing page at build time; not every Flash model has free audio). Build a small test set of 20–30 sample recordings (English, Hindi, mixed) during development to check accuracy.

## 9. App Screens

1. **Login** — "Sign in with Google"; "not invited" message for unknown emails
2. **Onboarding** — notification permission, battery optimization/autostart guide, offline speech pack (English + Hindi) prompt, app lock setup
3. **Home / Overview** — site cards with totals, grand total, sync status banner
4. **Site screen** — totals, category breakdown, entry list with search and filters, floating "+" (voice) and "manual" buttons
5. **Add/Edit entry** — form, photo attach, voice fill
6. **Entry detail** — all fields, photos, edit history, edit/delete buttons
7. **Activity feed** — all actions across sites
8. **CEO: Manage users** — invite by email and phone, list users (no remove/deactivate control)
9. **CEO: Manage sites** — add, edit, archive
10. **CEO: Export** — download Excel (hidden for managers)
11. **Settings** — profile, app lock, notification help, sign out

## 10. Suggested Project Structure

```
/app                      Flutter project
  /lib
    /core                 theme, routing, formatting (₹, dates), constants
    /data                 Firestore models, repositories, Worker client, local upload queue
    /features
      /auth
      /onboarding
      /sites
      /entries
      /voice
      /activity
      /admin              users, sites, export (CEO)
      /settings
    main.dart
/worker                   Cloudflare Worker (TypeScript)
  /src
  /test
  /scripts                bootstrap-ceo.mjs
  wrangler.toml
/firebase
  firestore.rules
  firestore.indexes.json
  firebase.json
/tests
  /rules                  security rules tests
```

## 11. Build Milestones

### Milestone 1 — Foundation
- Firebase project on the **Spark plan** (no billing account); Firestore in asia-south1; Google sign-in provider enabled; emulators (Auth, Firestore) configured
- Cloudflare account (free, no card); Worker skeleton with ID-token verification, service-account token caching, Firestore REST, and Identity Toolkit REST transports; secrets set
- Flutter app skeleton, routing, theme, Indian formatting
- Google sign-in, invite-by-email flow (`/invites/create`, `/signup/complete`), custom claims, deactivation (`/users/set-active`), CEO bootstrap script
- Security rules + tests for users/invites; Worker tests for the auth routes

**Done when:** the CEO can sign in with Google, invite a manager by email, and the manager can sign in; uninvited Google accounts are blocked; a deactivated manager loses access immediately.

### Milestone 2 — Sites and Manual Entries
- Sites CRUD (CEO), site screens, overview screen
- Manual add/edit/soft-delete of entries, each written in one batch with its history and activity docs
- Totals computed in the app (aggregation queries online, last known totals offline)
- Entry detail with edit history
- Rules + tests for sites/entries/history/activity

**Done when:** entries can be added, edited, and deleted; totals are correct; history shows every change; any write without a matching, correct history doc is rejected by the rules; history cannot be altered.

### Milestone 3 — Photos and Offline
- Cloudinary account (free, no card); Worker `/photos/sign-upload` and `/photos/view-urls`
- Bill photo capture, compression, upload
- Firestore offline persistence verified
- Persistent local photo upload queue with retry
- Sync indicators and banner
- Offline edit conflicts: last write wins with conflict-marked history and the entry note; rejected writes shown in the sync banner

**Done when:** in airplane mode, a manager can add an entry with a photo, close the app, reopen it later online, and the entry, its history, and the photo all sync correctly; a photo URL without a valid signature cannot be opened; two phones editing the same entry (one offline) end with the later-synced edit applied, both versions in history, and the conflict note shown.

### Milestone 4 — Notifications and Activity
- FCM client setup, token management, notification channel
- Worker `/notify` + cron sweep; sends to all active users except the actor; invalid-token cleanup
- Tap-to-open entry
- Activity feed
- Battery optimization onboarding

**Done when:** every add/edit/delete on one phone produces a correct, detailed notification on the other two within seconds, and a change that synced while the app was closed still produces its notification (via the sweep) within a few minutes.

### Milestone 5 — Voice Entry
- Audio recording UI
- Gemini parsing with JSON schema (Firebase AI Logic, Gemini Developer API free tier)
- Pre-filled confirm/edit form
- Accuracy check against the sample recording set
- Confirm the chosen model's free daily quota covers expected use
- Automatic on-device fallback (speech_to_text + on-device parser) for offline, errors, and quota; offline speech pack prompt in onboarding

**Done when:** typical spoken entries in English, Hindi, and mixed speech produce correct pre-filled forms, and nothing saves without confirmation. In airplane mode, or with Gemini forced to fail or return a quota error, voice entry still produces a pre-filled form via the on-device path.

### Milestone 6 — Excel Export and Polish
- On-device Excel export and CEO export screen (Open / Share); hidden for managers
- Search and filters on site screens
- App lock
- App Check enforced on Firestore, Firebase AI Logic, and the Worker
- Excel library spike (Decision 8) before building the export
- Backup reminder banner for the CEO when the last export is more than 7 days old
- Release builds (Android first)
- **Release checklist:** turn on Worker App Check enforcement (remove `APP_CHECK_ENFORCE = "false"` from `wrangler.toml` and deploy) once release clients send valid tokens; remove test accounts (delete their `invites`/`users` docs and Firebase Auth accounts via a script), bootstrap the real CEO's email, and have the CEO invite the real managers. Test data (sites/entries) is removed too, or the project starts clean.

**Done when:** the CEO can generate a correct workbook (sheet per site + All Sites summary) matching the app's totals exactly, with working photo links; managers cannot see or trigger export.

## 12. Out of Scope for v1 (Possible Later)

- Budgets per site/category with alerts
- Vendor management and outstanding dues
- Labour attendance and wages
- Cash advances to managers and reconciliation
- Rate comparison across sites
- Money received from clients / profit per site
- Web dashboard

The data model should not block any of these later.

## 13. Decisions

### Decided (2026-09-25)
1. **Photo links (app and Excel):** non-expiring Cloudinary signed delivery URLs. Anyone with a link can view the photo; accepted because the export file stays with the CEO. (Time-limited links would need Cloudinary's paid plan or would break inside old Excel files.)
6. **Voice:** use the Gemini Developer API free tier, accepting that Google may use submitted audio and responses to improve its products, and that human reviewers may read them. It falls back automatically to on-device speech recognition when Gemini is offline, failing, or over quota (Section 8), so voice entry always works.
7. **Offline edit conflicts:** last write wins, field by field. History keeps both versions (the overwriting record is marked `conflict` and names the change it overwrote), and the entry shows "Edited by someone else while you were offline" (Sections 3.3, 5, 7).
8. **Excel library:** spike the `excel` package first (frozen header, rupee number format, column widths, hyperlinks). If it falls short, use another maintained pure-Dart library whose license allows commercial use. Syncfusion is avoided because of its community-license revenue limits.
9. **Backups:** accept the weekly Excel export as the only backup (it excludes history, activity, and deleted entries), plus a reminder banner for the CEO when the last export is more than 7 days old.
- **Worker language:** TypeScript (time-app's JavaScript Worker is ported, not copied).

### Decided (2026-09-26)
2. **Moving an entry to a different site:** allowed for both managers and the CEO. The site change must be included in the immutable history record, just like every other user-visible change.
- **Distribution:** Android only and no Google Play Store listing. Releases will be installed directly from a trusted APK host. SMS invitation links open the installed app or an APK installation page; Google sign-in with the invited email remains mandatory.
- **APK host:** use this project's existing GitHub Releases. Possessing the APK or repository access never grants application access; only an unclaimed CEO-created invite for the verified Google email can create a user.

### Decided during implementation (2026-09-27)
3. **Photo-only updates:** log in the activity feed only; do not send a push.
4. **Deleted entries in Excel:** exclude them entirely, matching the weekly-backup definition.
5. **iOS:** Android only for v1.

### Decided (2026-10-25)
- **Quantity** is optional free text (Section 3.2). Rules accept text (1–60 characters), null, or the positive numbers saved earlier.
- **Grand total** on the Overview is collapsed by default and shown on tap.
- **Cloudinary signatures** use SHA-1, Cloudinary's default (the earlier SHA-256 switch was based on what turned out to be a wrong API secret).
- **Worker App Check** runs in monitor mode (`APP_CHECK_ENFORCE = "false"` in `wrangler.toml`) until Play Integrity and the debug token are registered: unattested requests are logged, not rejected. Removing that line is part of the release checklist.

## 14. Existing Code Reuse (Optional Step)

The owner has another near-complete app. Before Milestone 1, if pointed to it, do a **quick, targeted scan** (not a full review):
1. List the project structure and identify the stack.
2. Report which pieces could be reused here (e.g. auth flow, FCM setup, Firestore repository patterns, security rules, Worker utilities, UI components) with file paths.
3. Wait for approval before reading those files in depth or copying anything.

## 15. Free-Tier Limits

Checked on 2026-09-25 against each provider's pricing/limits page. Recheck before release, because free tiers change.

**Expected usage:** 3 users, ~30 entries/day, most with one photo, a few edits, a handful of voice entries, one CEO export per week.

| Service | Free limit | Our expected use | Fits? |
|---|---|---|---|
| **Firestore** (Spark) | 1 GiB stored; 50K reads/day; 20K writes/day; 20K deletes/day; 10 GiB/month egress. Every query costs at least 1 read; rules `get()` calls count as reads; a listener that reconnects after more than 30 min is re-billed in full. | Writes: ~30 entries × 3 docs (entry + history + activity) + ~30 photo attaches × 3 + edits + token updates ≈ **250–300/day (~1.5%)**. Reads: paginated lists, activity feed, aggregation totals, rules lookups, Worker sweep (1 query per run = 720/day) ≈ **a few thousand/day**; a full export reads every entry once (~11K in year 1, weekly). Storage ≈ 3 KB per entry incl. history/activity → **~35 MB/year**. | Yes, comfortably, **provided totals use aggregation queries and lists are paginated** (Section 5). Don't run exports daily once entries exceed ~20K. |
| **Firebase Auth** | 50K monthly active users | 3 | Yes |
| **FCM** | No cost | ~100 pushes/day | Yes |
| **App Check** | No cost; attestation providers have their own quotas (Play Integrity) | A few hundred attestations/day | Yes (confirm Play Integrity quota at Milestone 6) |
| **Cloudflare Workers** (Free) | 100,000 requests/day; 10 ms CPU per request; 50 subrequests per request; 5 cron triggers per account; 128 MB memory; 64 vars/secrets per Worker | ~720 cron runs + ~300 app calls ≈ **~1,000/day (~1%)**; 1 cron trigger; each notify ≈ 1 Firestore read + 3 FCM sends + 1 write | Yes. CPU is the tight one: cache the OAuth token and Google's public keys in memory. time-app's Worker already runs this pattern on the free plan. |
| **Cloudinary** (Free) | 25 credits/month; 1 credit = 1 GB storage **or** 1 GB bandwidth **or** 1,000 transformations; 3 users; no card | ~30 photos/day × ~400 KB ≈ **0.35 GB/month of growth** → ~4.3 GB stored after year 1; bandwidth for thumbnails/full views ~1–2 GB/month; transformations well under 1,000/month | Yes for several years: about 7 credits/month at the end of year 1, reaching 25 around year 4–5 at this rate. Revisit then (e.g. archive old photos). |
| **Gemini Developer API** (free tier, via Firebase AI Logic on Spark) | Available on Spark with no payment method. Free audio input only on some Flash models (currently the 3.6/3.7/3.8 Flash and 2.5 Flash/Flash-Lite families; **not** 3.5 Flash). Per-model limits are shown only in AI Studio per project; third-party reports for current Flash models range from ~20 to ~1,500 requests/day and ~10–15 requests/minute. Free-tier data may be used by Google (accepted, Decision 6). | ~5–30 voice entries/day | **Probably**, but not confirmed. Check the project's actual RPD in AI Studio at Milestone 5. If it's at the low end (~20/day), Gemini can run out on busy days; voice then continues on the automatic on-device fallback (no quota). |

**Not available on Spark (so not used):** Cloud Functions, Cloud Storage for Firebase, scheduled backups, point-in-time recovery, Firestore managed export/import.
