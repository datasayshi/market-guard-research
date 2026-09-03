#!/usr/bin/env python3
"""Integer mirror and randomized checks for MarketGuardReference.sol."""

from __future__ import annotations

import argparse
import random

WAD = 10**18
BASE_FEE_PIPS = 2_500
CORE_CAP_PIPS = 10_000
SURCHARGE_AT_UNIT_STRESS_PIPS = 20_000
FAST_DECAY_PER_SECOND_WAD = 962_223_836_894_145_152
SLOW_DECAY_PER_SECOND_WAD = 990_800_613_265_229_568
FAST_DENOM_GROWTH_PER_SECOND_WAD = 1_040_000_000_000_000_000


def rpow(x: int, n: int, scalar: int = WAD) -> int:
    if n == 0:
        return scalar
    z = x if n % 2 else scalar
    n //= 2
    while n:
        x = (x * x + scalar // 2) // scalar
        if n % 2:
            z = (z * x + scalar // 2) // scalar
        n //= 2
    return z


def bootstrap(active: int) -> int:
    if active == 0:
        raise ValueError("zero liquidity")
    return active // 10


def update_trusted(trusted: int, active: int, elapsed: int) -> int:
    if active == 0 or active <= trusted:
        return active
    return min(active, trusted + active * elapsed // 240)


def update_fast_denom(denominator: int, target: int, elapsed: int) -> int:
    if target <= denominator:
        return target
    ceiling = denominator * rpow(FAST_DENOM_GROWTH_PER_SECOND_WAD, elapsed) // WAD
    return min(target, ceiling)


def decay(value: int, per_second_wad: int, elapsed: int) -> int:
    factor = rpow(per_second_wad, elapsed)
    # Solidity signed division truncates toward zero.
    product = value * factor
    return product // WAD if product >= 0 else -((-product) // WAD)


def core_fee_pips(stress_wad: int) -> int:
    sqrt_stress_wad = _isqrt(stress_wad * WAD)
    return min(CORE_CAP_PIPS, BASE_FEE_PIPS + SURCHARGE_AT_UNIT_STRESS_PIPS * sqrt_stress_wad // WAD)


def _isqrt(x: int) -> int:
    if x == 0:
        return 0
    z = 1 << ((x.bit_length() - 1 + 1) >> 1)
    for _ in range(7):
        z = (z + x // z) >> 1
    return min(z, x // z)


def fuzz(steps: int, seed: int) -> None:
    rng = random.Random(seed)
    trusted = bootstrap(10**24)
    fast_denoms = [trusted, trusted]
    fast_stress = [0, 0]
    slow_pressure = 0

    for _ in range(steps):
        elapsed = rng.randrange(0, 301)
        active = rng.randrange(1, 10**25)
        old_trusted = trusted
        trusted = update_trusted(trusted, active, elapsed)
        assert 0 <= trusted <= active
        if active <= old_trusted:
            assert trusted == active
        else:
            assert old_trusted <= trusted <= old_trusted + active * elapsed // 240

        direction = rng.randrange(2)
        old_denom = fast_denoms[direction]
        fast_denoms[direction] = update_fast_denom(old_denom, trusted, elapsed)
        assert 0 <= fast_denoms[direction] <= max(old_denom, trusted)

        fast_stress[direction] = decay(fast_stress[direction], FAST_DECAY_PER_SECOND_WAD, elapsed)
        trade_stress = rng.randrange(0, 5 * WAD)
        fast_stress[direction] += trade_stress
        slow_pressure = decay(slow_pressure, SLOW_DECAY_PER_SECOND_WAD, elapsed)
        slow_pressure += trade_stress if direction == 0 else -trade_stress

        fee = core_fee_pips(fast_stress[direction])
        assert BASE_FEE_PIPS <= fee <= CORE_CAP_PIPS

    fast_half = decay(WAD, FAST_DECAY_PER_SECOND_WAD, 18)
    slow_half = decay(WAD, SLOW_DECAY_PER_SECOND_WAD, 75)
    assert abs(fast_half - WAD // 2) <= 10_000
    assert abs(slow_half - WAD // 2) <= 10_000
    print(f"PASS: {steps:,} randomized transitions; seed={seed}")
    print(f"fast_half={fast_half} slow_half={slow_half} final_fee={fee}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--steps", type=int, default=1_000_000)
    parser.add_argument("--seed", type=int, default=38)
    args = parser.parse_args()
    fuzz(args.steps, args.seed)
