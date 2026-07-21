# Pharos — Licensing & Pricing Decision

> **DECISION (2026-06): Pharos is open source under the [MIT License](../LICENSE).**
> The author chose to open-source it and self-distribute (notarized DMG + Sparkle).
> The options analysis below is kept as the rationale/history that led to MIT.

---

## 1. Option Analysis

### Option A — Proprietary / All Rights Reserved (current stance)

Keep the source private, no redistribution permitted.

| Pros | Cons |
|------|------|
| Full control over distribution and forks | Zero community contribution |
| Simplest legal posture (no CLA, no compatibility matrix) | "Trust me" privacy story — no public audit trail |
| No risk of a competitor packaging your code | May deter curious users who want to inspect what the app reads from `~/.claude` |
| Preserves commercial optionality at any time | GitHub stars / credibility signal unavailable |

**Best fit for:** an author who wants zero overhead, zero support requests from strangers, and maximum future flexibility (including selling later).

---

### Option B — Open Source (MIT or Apache-2.0)

Publish the source with permissive terms.

| Pros | Cons |
|------|------|
| Community can file issues, send PRs, audit privacy claims | Anyone can fork and redistribute, including commercially |
| Developer-tool credibility signal | Support burden grows with visibility |
| MIT is legally minimal — zero friction for contributors | Apache-2.0 adds a patent clause (good for protection; slightly more verbose) |
| Builds goodwill in the vibe-coding community | Hard to monetize later without a CLA or code relicense |

**MIT vs Apache-2.0 for this app:** Apache-2.0 is marginally better — it includes an explicit patent retaliation clause and is OSI-approved. For a niche personal tool the difference is academic; pick whichever SPDX string you prefer.

**Best fit for:** an author who wants the privacy/trust signal that comes from readable source, values community contributions, and is comfortable with the app being forked.

---

### Option C — Source-Available (PolyForm Noncommercial or BSL 1.1)

Code is publicly readable; commercial use is restricted.

**PolyForm Noncommercial 1.0.0** — free for personal/non-commercial use, no commercial use allowed. Clean, plain-English license maintained by lawyers. Good fit for an indie dev tool where you want transparency without handing competitors a free product.

**Business Source License 1.1 (BSL/BUSL)** — source is viewable; becomes a named open-source license (usually Apache-2.0) after a specified "Change Date" (commonly 4 years). Used by HashiCorp, MariaDB, Sentry. More complex; best suited when you expect a commercial product with enterprise buyers.

| Pros | Cons |
|------|------|
| Source is auditable (good for privacy story) | Neither is OSI-approved — some developers won't touch it |
| Restricts commercial redistribution | Extra license complexity; PolyForm is newer and less battle-tested |
| Can layer a paid tier on top later | BSL change-date requires ongoing maintenance decision |
| Signals "indie, not abandoned" | Community PRs are legally complicated (CLA needed for BSL) |

**Best fit for:** an author who wants the privacy credibility of public source but wants to preserve a paid-license commercial lane.

---

### Option D — Paid / Freemium (direct distribution)

Charge for the app or offer a free tier + paid features.

Pharos is already set up well for this:

- **Developer ID + notarization** is already wired — distributing outside the Mac App Store is the plan.
- **Sparkle auto-update** is already integrated — users get seamless paid upgrades.
- No Mac App Store means no 30% cut and no sandboxing restrictions (which is why private macOS APIs are usable).

**Fulfillment options:**

| Service | Notes |
|---------|-------|
| **Gumroad** | Simplest. One-time or subscription. License-key delivery via email. No SDK required. |
| **Paddle** | More robust merchant-of-record (handles EU VAT, etc.). Better for recurring subscriptions. |
| **Lemon Squeezy** | Stripe-powered, developer-friendly API, good license-key system. Growing indie-dev favorite. |

**macOS notarization implications:** Notarization applies to the binary, not the license. You notarize once per build regardless of whether it's free or paid. If you add a license-key check at launch, that code runs locally — no impact on the notarization process itself.

**Pricing anchors for a niche dev tool:**
- One-time: $19–$49 is the sweet spot for "serious dev tool, indie priced."
- Subscription: $5–$9/mo is typical for utilities with active development.
- Freemium: core free, advanced session browser / worktree manager paid.

| Pros | Cons |
|------|------|
| Monetizes your time and keeps the project alive | Adds license-key / payment infrastructure work |
| Infrastructure already in place (Sparkle + Developer ID) | Small niche (vibe-coders) limits TAM |
| Can stay closed-source while still charging | Requires support channel (even just an email) |
| Gumroad/Paddle/Lemon Squeezy handle VAT globally | Community trust requires transparency (see privacy section) |

---

## 2. Recommendation

**Start with Option A (Proprietary, All Rights Reserved), and revisit Option D (paid) once P2 features ship.**

Reasoning:

1. **Lowest friction now.** Pharos is mid-build (P0/P1). A license debate is premature overhead. All Rights Reserved requires zero maintenance.
2. **The audience is tiny and trusting.** The current user base is the author. When it grows, it will be vibe-coders who follow the author's work — not strangers who need an OSI stamp.
3. **Privacy story is fine without open source.** A clear, explicit privacy section in the README / settings UI ("we read `~/.claude` locally and send nothing") is more user-facing effective than a public GitHub repo most users will never browse.
4. **Monetization lane stays open.** Going from All Rights Reserved → paid (Option D) is a one-step move: pick a payment processor, add a license check, update the README. Going from MIT → paid requires a full relicense negotiation.
5. **If the community/trust pull becomes strong** — e.g., users ask "what does this thing do with my Claude session history?" — pivot to Option C (PolyForm Noncommercial). It gives the transparency benefit with a commercial restriction that keeps forking at bay.

> **The final decision belongs to the author.** This document is a structured input, not a commitment.

---

## 3. Privacy Stance

Pharos reads two local directories:

- `~/.claude/projects/` — Claude Code session histories
- `~/.codex/sessions/` — Codex session histories

**What Pharos does NOT do:**

- It does not transmit any session data, file paths, or identifiers to any remote server.
- It does not include telemetry, analytics, or crash reporters (as of writing).
- All data remains on-device in `~/Library/Application Support/Pharos/`.

**Recommendation:** State this plainly in the README (one short bullet), in the onboarding screen, and in a SettingsView "Privacy" section. Users who manage AI session data are sensitive about what apps touch those files; a brief, confident disclosure builds more trust than silence.

**Telemetry policy:** If any future telemetry is added (e.g., crash reporting via Sentry), it **must** be:

- Opt-in only (off by default).
- Disclosed clearly in the onboarding flow.
- Documented in a PRIVACY.md or equivalent.

---

## 4. What to Change If You Pick X

### If you stay with Option A (All Rights Reserved — the current default)
- [ ] Keep the existing `LICENSE` file as-is.
- [ ] Update README's License line if desired (already says "Private. © 2026 Pai.").
- [ ] Add the privacy disclosure bullet to README.
- [ ] No other changes required.

### If you switch to Option B (MIT or Apache-2.0)
- [ ] Replace `LICENSE` with the MIT or Apache-2.0 SPDX text (name + year filled in).
- [ ] Update README license line: `MIT License` or `Apache-2.0`.
- [ ] Add `SPDX-License-Identifier: MIT` (or `Apache-2.0`) header to Swift source files if desired.
- [ ] Decide CLA policy (likely: not needed for a niche personal tool).
- [ ] Add the privacy disclosure bullet to README.

### If you switch to Option C (PolyForm Noncommercial)
- [ ] Replace `LICENSE` with the PolyForm Noncommercial 1.0.0 text (`https://polyformproject.org/licenses/noncommercial/1.0.0/`).
- [ ] Update README license line: `PolyForm Noncommercial 1.0.0`.
- [ ] Make the repo public on GitHub.
- [ ] Add a `CONTRIBUTING.md` that explains CLA requirements (or accept patches under the same license).
- [ ] Add the privacy disclosure bullet to README.

### If you add a paid tier (Option D)
- [ ] Choose a payment processor (Gumroad / Paddle / Lemon Squeezy).
- [ ] Implement a license-key validation step at launch (local, offline-capable is best UX).
- [ ] Set a price page / landing page (the `site/` directory is a natural home).
- [ ] Keep or swap the `LICENSE` depending on whether you also open-source (D can stack on B or C).
- [ ] Add a short purchase / upgrade flow note to README.
- [ ] Update Sparkle `appcast.xml` to carry version notes about paid features.
- [ ] No notarization changes needed — your current signing setup already covers paid distribution.

---

## Current License

The repository root `LICENSE` is the authoritative MIT License selected in
2026-06. The alternative models above are retained only as decision history.

---

*Document written 2026-06-19. Revisit when P2 (session browser) ships or when first
external user appears.*
