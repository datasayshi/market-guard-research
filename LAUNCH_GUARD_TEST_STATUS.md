# Launch Guard 30 / Launch Guard 60 implementation and test status

## Version lineage

The established product names remain unchanged.

| Model | Previous record | Advanced reference |
|---|---|---|
| Launch Guard 30 | v1.0 candidate — Balanced-15 + 10m normalization tail | **v1.1 — net-flow hardened executable reference** |
| Launch Guard 60 | v0.3 — battle-tested 60m profile | **v0.4 — net-flow hardened executable reference** |

The phase durations and numeric `I(t)` / `r(t)` / `S(t)` schedules are unchanged. The revisions harden semantics that can be tested without pretending the schedule has been optimized against unavailable live-launch replay data.

## Preserved principles

- Maximize useful functionality per unit of trading friction.
- Zero Launch Guard surcharge.
- No wallet identity, bot classifier, allowlist, or external sequencer.
- Global per-pool acquisition control rather than a per-block reset.
- `I(t)` controls burst capacity, `r(t)` controls sustained net acquisition, and `S(t)` controls one-swap concentration.
- A widening normalization tail replaces a hard fee or capacity cliff.

## v1.1 / v0.4 advances

### 1. Liquidity-linked explicit activation

The clock no longer starts implicitly at pool initialization. `activate` receives an immutable protected-supply amount and the timestamp at which authorized launch liquidity becomes usable. The state rejects all guarded flows before activation and cannot be reactivated.

The arithmetic library cannot authenticate the caller. A production hook must restrict activation to the trusted launch factory / manager and make it atomic with the authorized initial-liquidity transaction.

### 2. Explicit protected supply

The design no longer calls token `totalSupply()` during initialization. The launch path supplies a factory-validated protected amount between 200 base units and `uint128.max`. This makes the denominator an intentional launch-policy choice and avoids silent coupling to burns, rebases, or unrelated circulating inventory.

### 3. Net guarded-token outflow accounting

Successful buys consume actual guarded-token output. Successful sells restore actual guarded-token input, capped at the current `I(t)` bucket. A buy/sell round trip therefore cannot permanently burn public capacity while leaving the attacker approximately inventory-neutral.

This does not create buyer fairness. A fast participant can still capture released capacity, and `S(t)` can be split across transactions or addresses. Launch Guard controls aggregate pool outflow, not identity-level allocation.

### 4. Exact lazy accounting

- Refill is integrated piecewise across every rate-schedule segment.
- Fractional token capacity is retained in a bounded remainder, including at the bucket ceiling, so frequent updates and a single lazy update agree even for small protected supplies.
- Capacity is capped at every schedule boundary. This prevents refill discarded under an earlier, lower `I(t)` from reappearing when the widening tail raises the bucket ceiling.
- Raising `I(t)` never directly mints capacity.
- Same-timestamp transitions receive zero refill.

The boundary-cap rule materially corrects the naive final-time formula. For an untouched saturated profile, available capacity at LG30 minute 25 and LG60 minute 50 is **7.8125%**, not the then-current 8.5% bucket ceiling: only the 2% capacity bankable at the tail boundary plus 5.8125% tail refill is available.

### 5. Deterministic quote helpers

The reference exposes active status, available capacity, per-swap limit, maximum currently valid buy, refill rate, retirement countdown, and an exact `secondsUntilBuy` search assuming no intervening swaps. The wait calculation belongs in an off-hook lens or frontend so it adds no swap-path gas.

## Locked schedules

### Launch Guard 30

| Time | `I(t)` bucket | `r(t)` per minute | `S(t)` per swap |
|---|---:|---:|---:|
| 0–5m | 1.00% | 0.50% | 0.50% |
| 5–10m | 1.00→1.25% | 0.65% | 0.50→0.75% |
| 10–20m | 1.25→2.00% | 0.825% | 0.75→1.00% |
| 20–30m | 2.00→15.00% | 0.825→2.175% | 1.00→10.00% |
| 30m | retires | — | — |

### Launch Guard 60

| Time | `I(t)` bucket | `r(t)` per minute | `S(t)` per swap |
|---|---:|---:|---:|
| 0–10m | 1.00% | 0.25% | 0.50% |
| 10–20m | 1.00→1.25% | 0.325% | 0.50→0.75% |
| 20–40m | 1.25→2.00% | 0.4125% | 0.75→1.00% |
| 40–60m | 2.00→15.00% | 0.4125→1.0875% | 1.00→10.00% |
| 60m | retires | — | — |

Both profiles retain the same saturated cumulative release knots and reach 30% at retirement. Launch Guard 60 remains the deliberate stronger-control profile rather than a premium/default choice.

## Intended Uniswap v4 callback mapping

1. Pool initialization registers an unarmed pool but does not start the clock.
2. The trusted launch path adds the intended initial liquidity and activates the guard atomically with the validated protected supply.
3. `beforeSwap` rejects swaps while unarmed. For exact-output buys it can fail fast against a non-mutating quote, without committing capacity.
4. `afterSwap` derives actual guarded-token flow from `BalanceDelta`:
   - guarded token out: apply the buy checks and consume capacity;
   - guarded token in: settle and credit the sell, capped at `I(t)`.
5. At the exact retirement timestamp, Launch Guard returns to unrestricted AMM behavior.

No dynamic-fee or return-delta permission is required by this design.

## Current evidence

Implemented:

- Solidity 0.8.26 standalone arithmetic/state reference.
- Integer-equivalent Python mirror.
- Deterministic schedule, release-knot, activation, retirement, quote, rounding, and round-trip-grief tests.
- Foundry fuzz coverage for schedule monotonicity, exact integral additivity, transition bounds, and update-path neutrality.
- Randomized Python lifecycle transitions for both profiles.

Not yet proven:

- Actual `BaseHook` callback selectors and hook-address permission bits.
- `PoolId` storage integration and authorized factory activation.
- Correct guarded-token direction and signed `BalanceDelta` interpretation in real swaps.
- Exact-input, exact-output, partial-fill, multi-hop, nested-pool, and concurrent-router behavior.
- Storage/gas measurements for the production hook.
- Robinhood/Uniswap v4 fork tests, historical launch replay, audit, deployment, or production readiness.

## Next evidence gate

Implement the real Uniswap v4 hook adapter around this frozen reference, then run unit and invariant tests against PoolManager before changing any phase parameter. Parameter changes should be justified by reproducible launch-depth and demand replays, with Launch Guard 30 as the balanced reference and Launch Guard 60 as the stricter challenger.
