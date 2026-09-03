# Market Guard recovery and test status

## Authority

- Airtable `Hook Intelligence Lab` / `Design Candidates` is the latest structured record.
- Current record version: **v0.38 — executable reference / million-step fuzz / replay-harness baseline**.
- Retained mechanism architecture: **v0.33 shared core**.
- The GitHub repository contained only its README when recovered on 2026-09-03.

## Recovered rules implemented here

- Bootstrap trusted liquidity at 10% of observed active liquidity.
- Recognize trusted-liquidity decreases immediately.
- Limit upward trusted-liquidity recognition to 25% of current active liquidity per minute.
- Maintain direction-local fast denominators, downward immediately and upward at approximately 4% compounded per second.
- Fast-stress decay with an approximately 18-second half-life.
- Signed slow-pressure decay with an approximately 75-second half-life.
- Core fee: 25 bp + 2.0% × sqrt(price-normalized local stress), capped at 100 bp.
- Marginal cumulative sqrt-pricing reference.

## Evidence boundary

`MarketGuardReference.sol` is a standalone arithmetic reference, not a deployable Uniswap v4 hook. The recovered records do not contain enough source-level detail to recreate exact callback wiring, BalanceDelta interpretation, settlement handling, storage packing, transient same-pool locking, or the final slow cap-only controller without making new design decisions. Those items remain explicit hard gates.

No files have been pushed to GitHub.
