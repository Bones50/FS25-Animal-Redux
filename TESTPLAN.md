# Animal Redux — feed planning test plan

Covers the feed model end to end: Distribution Redux's extension API, Animal Redux's
planner, and whether animals actually produce more.

Deployed for this plan: **DR 15:13:37**, **Animal Redux 15:13:37** (both 2026-08-22).
Lua changed in both, so this needs a **full game restart**, not a save reload.

Console commands need `game.xml <development><controls>true` — already on.

---

## A · It loads and links (2 minutes, no gameplay)

Restart, load the save, then search `log.txt` for `AnimalRedux` and `SmartDistribution API`.

| # | Expect | If it's wrong |
|---|---|---|
| A1 | `[SmartDistribution] extension API v1 available` | DR didn't deploy, or `DistributionAPI.lua` is missing from modDesc |
| A2 | `[AnimalRedux] ... linked to Distribution Redux (global 'FS25_Distribution_Redux', **API v1**)` | if it says **API v0**, DR's zip is stale — redeploy DR |
| A3 | `[SmartDistribution API] feed planner 'FS25_Animal_Redux' registered` | AR found DR but not the API — check A2 first |
| A4 | `[AnimalRedux] feed planning ACTIVE (Distribution Redux API v1)` | the headline line; if absent, nothing below will work |
| A5 | `[AnimalRedux] l10n OK` | translations resolving |

**Stop here if A4 is missing.** Everything after it depends on the planner being registered.

---

## B · The model still agrees with the engine (2 minutes, console)

### B1 — `arFeedPlan`

- `MODEL AGREES with the engine` on **all five** animal types.
- `VERDICT model beats DR today: 1.0000 vs 0.5000 (+100.0%)` on **Pigsty**.
- `... 1.0000 vs 0.5714 (+75.0%)` on **Horse Barn**.
- `VERDICT no change` on **Cow**, **Sheep**, **Chicken**.

Any `MODEL DISAGREES` line is a stop-and-report: the engine is right and the model is wrong
for that animal.

### B2 — `arFeedPartial`  ← **new information, not a pass/fail**

This answers the one thing still unmeasured: whether a group only has to be *present*, or has to
be *stocked to its share*.

Read the Pigsty and Horse Barn rows:

- **`1 L` column already equals the `200%` column** → presence-based. A trickle of every group is
  enough, and sourcing is easy.
- **The row climbs left to right** → quantity-based. Every group must be kept to its share every
  hour, and DR's sourcing has to keep up.

Send me the output either way — it decides whether the current design is sufficient.

---

## C · It actually moves product (the real test)

**Setup.** Pick the **Pigsty**. Confirm the farm has, inside DR's radius and not blocked:

- a Base food crop — `MAIZE` or `SORGHUM`
- a Grain — `WHEAT` or `BARLEY`
- a Protein — `SOYBEAN`, `CANOLA` or `SUNFLOWER`
- a Root crop — `POTATO`, `SUGARBEET`, `CARROT`, `PARSNIP` or `BEETROOT`

If any group has no source anywhere, that's test **E2** instead, not a failure here.

| # | Do | Expect |
|---|---|---|
| C1 | Let **1 in-game hour** pass | — |
| C2 | Run `arFeedPlan` | the **CURRENT** row now lists **four different products**, not one |
| C3 | Read `CURRENT ... engine factor` | **1.0000** (it was 0.5000 under best-first) |
| C4 | Same on the **Horse Barn** | three products; factor **1.0000** |
| C5 | Same on the **Cow Barn** | still **FORAGE only** — a blend here would be a regression |

**The single most important line in the whole plan is C3.** A blended trough that still scores
0.5 would mean the blend is wrong; a 1.0 factor is the feature working.

Note the trough fills to DR's **buffer target** (`rate × bufferHours`), not to capacity, so it
won't look full. The *ratios* are what matter, not the volume.

---

## D · DR alone is unchanged (the inertness guarantee)

The API is supposed to do nothing for players who don't have Animal Redux.

| # | Do | Expect |
|---|---|---|
| D1 | Move `FS25_Animal_Redux.zip` out of the mods folder, restart | `extension API v1 available` still logs; **no** `feed planner` lines |
| D2 | Let an hour pass, run nothing | husbandries feed exactly as they did before today — a pig trough fills with a single crop |
| D3 | Put the zip back, restart | A4 returns |

D2 is the regression check that matters to your existing players.

---

## E · Edge cases

| # | Do | Expect |
|---|---|---|
| E1 | Advanced Inputs on the Pigsty → **block MAIZE**. Wait an hour, `arFeedPlan` | falls back to **SORGHUM** for the same group; factor stays **1.0000** |
| E2 | Block **every** Protein crop (soybean, canola, sunflower). Wait, re-check | factor caps at **0.8000**; the other three groups renormalise and the trough still fills |
| E3 | Block **everything** the Pigsty accepts | planner declines; DR behaves as before; **no errors in the log** |
| E4 | DR Settings → **feed husbandry OFF**. Wait an hour | nothing fed at all, and **no planner activity** — the hook is unreachable, not merely quiet |
| E5 | DR Settings → **include husbandry OFF** | husbandries leave the network entirely |

E4 is the second half of "does nothing if husbandry isn't being used" — E1–E3 test the planner,
E4 tests that it's never even reached.

---

## F · Stability

| # | Do | Expect |
|---|---|---|
| F1 | **Sleep 8+ hours** | no stutter on the hour; troughs stay blended |
| F2 | Save, reload, `arFeedPlan` | identical results — nothing here is persisted, so it must re-derive cleanly |
| F3 | Search the log for `STRUCK OUT` | **must not appear**. It means the planner threw three times and DR has fallen back for the session |
| F4 | Search for `planner ... rejected` / `dropped` | only expected during E1–E3 |

---

## Known gaps — not testable yet, don't chase them

- **Multiplayer.** Untested. The planner runs server-side inside the hourly pass, and nothing
  new is persisted or replicated, but that is reasoning, not evidence.
- **A group with no source anywhere** (E2's cousin). The planner still reserves that group's
  share, so the trough sits partly empty as well as short. The factor is capped either way; the
  fix needs a "can DR source this?" query, which is an API v2 item.
- **Depletion over a long run.** The harness models it (100 h vs 53 h for a horse), but it has
  never run through a real in-game month.
- **Modded animal types.** RealisticLivestock changes demand but not the food groups, so it
  should be unaffected — worth one `arFeedPlan` with RL active to confirm.

---

## Quick path

If you only have five minutes: **A4**, then **B1**, then **C3**. Those three confirm the chain is
connected, the model is right, and product is actually moving.
