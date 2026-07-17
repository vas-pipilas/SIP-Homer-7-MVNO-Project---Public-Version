# Case Study: Chasing a Phantom 5-Point Metric Gap

## The symptom

The platform's hourly call-quality report showed a persistent, structural
pattern: nodes on the "edge" tier (facing the carrier interconnect) always
reported a 5-7 point higher Answer Seizure Rate (ASR — the percentage of
call attempts that get a real answer) than nodes on the "application" tier
(a B2BUA one hop further into the network), across every site, every hour,
every day. It was small enough to dismiss as noise, but consistent enough
that it clearly wasn't.

This is the story of finding the real cause — which took six wrong turns
before the right one, each ruled out with actual data rather than assumed
away.

## Hypothesis 1: it's a raw-volume artifact

The edge tier's raw INVITE volume was roughly double the application tier's.
Digging into the actual call flow, this made sense architecturally: a single
real call generates four distinct SIP dialogs at the edge tier (carrier-in,
edge-to-app relay, app-to-edge new dialog, edge-to-carrier-out) but only two
at the application tier (it only ever sees the middle two). Confirmed this
by directly matching real call legs across both tiers — near-100%
correspondence.

**But this can't explain a percentage gap.** If every leg of the same call
shares an identical outcome, then `4×answered / 4×total` reduces to exactly
the same fraction as `2×answered / 2×total` — a constant multiplier cancels
out of a ratio. The volume difference was real and fully explained; it had
nothing to do with the percentage gap. Ruling this out took actual
leg-correspondence testing, not just accepting the "obvious" math — it's
worth confirming, because if the two tiers had ever disagreed on which leg
belonged to which call, the multiplier argument would have broken down.

## Hypothesis 2: SIP response codes get remapped between hops

B2BUA-style elements sometimes normalize less-common response codes when
relaying signaling across a boundary (a `603 Decline` becoming a `486 Busy
Here`, for instance). Tested this directly: for a large sample of real,
correlated call pairs, compared the final SIP response code on each tier's
leg.

**Result: >97% exact match.** The handful of mismatches were response-code
pairs like `487`/`480` — both already "unanswered," so even where codes
genuinely diverged, it never crossed the answered/unanswered boundary that
ASR actually measures. Ruled out.

## Hypothesis 3: the upstream SBC is retry-flooding failed attempts

If a carrier-side element retries a failed INVITE under a fresh Call-ID
multiple times, and only one attempt happens to reach the deeper tier, that
would inflate one tier's failure count without touching the other's. Checked
this by bucketing every destination number by minute and counting repeat
attempts.

**Result: only ~2% of numbers showed more than one attempt per minute.**
Nowhere near enough volume to produce a multi-point gap. Ruled out.

## Hypothesis 4: inbound and outbound legs of the same call diverge

Since the application tier is a true back-to-back user agent, it decouples
the inbound and outbound legs of a call by design — in principle they could
resolve differently. Correlated ~5,500 real inbound/outbound leg pairs and
compared final outcomes directly.

**Result: 99.93% match — only 4 mismatches, and those were an artifact of
catching an in-flight provisional response (`183`) mid-query, not a real
divergence.** If A-side and B-side outcomes agree this consistently, blending
all four legs together mathematically *should* produce a gap under 0.1
points — not 5-7. This was the moment the "it's something architectural
about how the legs are counted" family of explanations ran out of road
entirely. Something else had to be composing the two tiers' raw traffic
differently.

## The real cause: a hidden non-subscriber traffic category

Re-reading the *actual* production query (rather than the hand-scoped
diagnostic queries used for every hypothesis above) surfaced the real gap: it
had no destination-address filtering at all — it counted *everything*
tagged as an INVITE at each node, not just verified call-flow traffic.

Pulling a full breakdown of destination addresses by node revealed a
consistent secondary population: internal service-platform destinations —
voicemail and IVR routing codes, syntactically nothing like a real subscriber
number — that had been silently counted as ordinary call attempts the whole
time.

These calls answer at approximately **0.06%**, essentially never — which
makes sense, since they're not real two-party call attempts. Critically:

- This traffic made up a consistent **~5.5%** of the edge tier's total
  INVITE volume
- It made up a consistent **~14-15%** of the application tier's — roughly
  **2.7×** more, every single day tested

That asymmetry, combined with a near-zero answer rate, is a mechanism that
can genuinely produce a percentage gap where equal leg-counting cannot: a
metric's denominator got polluted by a different amount on each tier.

## Validating before touching production

Rather than ship a fix off one convincing result, the theory was tested
across **three separate days**, each compared using the identical
methodology:

| Day | Edge-tier ASR (subscriber-only) | App-tier ASR (subscriber-only) |
|---|---|---|
| Day 1 | 65.21% | 65.21% |
| Day 2 | 66.75% | 66.75% |
| Day 3 | 65.59% | 65.59% |

Once the non-subscriber traffic was excluded, the two tiers matched to
within **0.05 points**, every day. There was never a real quality difference
between the two tiers — the entire gap was a counting artifact.

## A false start, caught before it did damage

The first fix attempt had its own bug: the filtering regex didn't account
for the literal `+` character present in nearly every real subscriber
number, so it would have excluded most **real** calls rather than the
handful of service-platform ones. Caught on review before deployment,
reverted cleanly, and re-validated properly against all three days of real
data (not just one hand-picked example) before the corrected version went
out — including verifying the exact SQL a shell script would actually send
to the database, since a subtle string-escaping difference is exactly what
caused the first bug.

## Outcome

The corrected report now cleanly separates subscriber-facing ASR from
excluded service/announcement traffic, showing both explicitly rather than
silently dropping one — so the exclusion itself stays auditable, not hidden.
First live report after deployment showed the two tiers landing within a
few points of each other, no longer following the old structural pattern.

## What this shows

- Ruling out plausible-sounding explanations with real correlated data,
  not just accepting "the math should work out"
- Recognizing when a chain of hypotheses has genuinely run out of road,
  rather than reaching for a sixth guess
- Going back to read the actual production code rather than continuing to
  build increasingly elaborate diagnostics around it
- Catching a real bug in a fix on review, reverting without ego, and
  re-validating properly rather than patching around it live
