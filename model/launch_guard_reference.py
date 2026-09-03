#!/usr/bin/env python3
"""Integer mirror and randomized checks for Launch Guard 30 / Launch Guard 60.

This mirrors src/LaunchGuardReference.sol, including the refill remainder that
makes repeated lazy updates equivalent to one update over the same interval.
"""

from __future__ import annotations

import argparse
import random
from dataclasses import dataclass
from enum import IntEnum

PPB = 1_000_000_000
REFILL_DENOMINATOR = PPB * 120
INITIAL_BUCKET_PPB = 10_000_000
MIN_PROTECTED_SUPPLY = 200
MAX_PROTECTED_SUPPLY = 2**128 - 1


class Profile(IntEnum):
    LAUNCH_GUARD_30 = 0
    LAUNCH_GUARD_60 = 1


@dataclass(frozen=True)
class State:
    protected_supply: int = 0
    capacity: int = 0
    activated_at: int = 0
    last_updated_at: int = 0
    capacity_remainder: int = 0
    activated: bool = False


@dataclass(frozen=True)
class Quote:
    active: bool
    available_capacity: int
    per_swap_limit: int
    max_buy: int
    refill_rate_ppb_per_minute: int
    seconds_until_retirement: int


class GuardError(Exception):
    pass


class NotActivated(GuardError):
    pass


class TimeRegression(GuardError):
    pass


class CapacityExceeded(GuardError):
    pass


class PerSwapLimitExceeded(GuardError):
    pass


def duration(profile: Profile) -> int:
    return 30 * 60 if profile == Profile.LAUNCH_GUARD_30 else 60 * 60


def lerp(start: int, end: int, offset: int, width: int) -> int:
    return start + (end - start) * offset // width


def bucket_limit_ppb(profile: Profile, elapsed: int) -> int:
    elapsed = min(elapsed, duration(profile))
    if profile == Profile.LAUNCH_GUARD_30:
        if elapsed <= 5 * 60:
            return 10_000_000
        if elapsed <= 10 * 60:
            return lerp(10_000_000, 12_500_000, elapsed - 5 * 60, 5 * 60)
        if elapsed <= 20 * 60:
            return lerp(12_500_000, 20_000_000, elapsed - 10 * 60, 10 * 60)
        return lerp(20_000_000, 150_000_000, elapsed - 20 * 60, 10 * 60)

    if elapsed <= 10 * 60:
        return 10_000_000
    if elapsed <= 20 * 60:
        return lerp(10_000_000, 12_500_000, elapsed - 10 * 60, 10 * 60)
    if elapsed <= 40 * 60:
        return lerp(12_500_000, 20_000_000, elapsed - 20 * 60, 20 * 60)
    return lerp(20_000_000, 150_000_000, elapsed - 40 * 60, 20 * 60)


def per_swap_limit_ppb(profile: Profile, elapsed: int) -> int:
    elapsed = min(elapsed, duration(profile))
    if profile == Profile.LAUNCH_GUARD_30:
        if elapsed <= 5 * 60:
            return 5_000_000
        if elapsed <= 10 * 60:
            return lerp(5_000_000, 7_500_000, elapsed - 5 * 60, 5 * 60)
        if elapsed <= 20 * 60:
            return lerp(7_500_000, 10_000_000, elapsed - 10 * 60, 10 * 60)
        return lerp(10_000_000, 100_000_000, elapsed - 20 * 60, 10 * 60)

    if elapsed <= 10 * 60:
        return 5_000_000
    if elapsed <= 20 * 60:
        return lerp(5_000_000, 7_500_000, elapsed - 10 * 60, 10 * 60)
    if elapsed <= 40 * 60:
        return lerp(7_500_000, 10_000_000, elapsed - 20 * 60, 20 * 60)
    return lerp(10_000_000, 100_000_000, elapsed - 40 * 60, 20 * 60)


def refill_rate_ppb_per_minute(profile: Profile, elapsed: int) -> int:
    elapsed = min(elapsed, duration(profile))
    if profile == Profile.LAUNCH_GUARD_30:
        if elapsed < 5 * 60:
            return 5_000_000
        if elapsed < 10 * 60:
            return 6_500_000
        if elapsed < 20 * 60:
            return 8_250_000
        return lerp(8_250_000, 21_750_000, elapsed - 20 * 60, 10 * 60)

    if elapsed < 10 * 60:
        return 2_500_000
    if elapsed < 20 * 60:
        return 3_250_000
    if elapsed < 40 * 60:
        return 4_125_000
    return lerp(4_125_000, 10_875_000, elapsed - 40 * 60, 20 * 60)


def cumulative_refill_numerator(profile: Profile, elapsed: int) -> int:
    elapsed = min(elapsed, duration(profile))
    if profile == Profile.LAUNCH_GUARD_30:
        first = min(elapsed, 5 * 60)
        result = 2 * 5_000_000 * first
        if elapsed <= 5 * 60:
            return result
        second = min(elapsed - 5 * 60, 5 * 60)
        result += 2 * 6_500_000 * second
        if elapsed <= 10 * 60:
            return result
        third = min(elapsed - 10 * 60, 10 * 60)
        result += 2 * 8_250_000 * third
        if elapsed <= 20 * 60:
            return result
        tail = elapsed - 20 * 60
        return result + 2 * 8_250_000 * tail + 22_500 * tail * tail

    first = min(elapsed, 10 * 60)
    result = 2 * 2_500_000 * first
    if elapsed <= 10 * 60:
        return result
    second = min(elapsed - 10 * 60, 10 * 60)
    result += 2 * 3_250_000 * second
    if elapsed <= 20 * 60:
        return result
    third = min(elapsed - 20 * 60, 20 * 60)
    result += 2 * 4_125_000 * third
    if elapsed <= 40 * 60:
        return result
    tail = elapsed - 40 * 60
    return result + 2 * 4_125_000 * tail + 5_625 * tail * tail


def integrated_refill_numerator(profile: Profile, start: int, end: int) -> int:
    if end < start:
        raise ValueError("invalid interval")
    return cumulative_refill_numerator(profile, end) - cumulative_refill_numerator(profile, start)


def cumulative_release_ppb(profile: Profile, elapsed: int) -> int:
    return INITIAL_BUCKET_PPB + cumulative_refill_numerator(profile, elapsed) // 120


def amount_from_ppb(supply: int, amount_ppb: int) -> int:
    return supply * amount_ppb // PPB


def activate(state: State, protected_supply: int, timestamp: int) -> State:
    if state.activated:
        raise GuardError("already activated")
    if not MIN_PROTECTED_SUPPLY <= protected_supply <= MAX_PROTECTED_SUPPLY:
        raise GuardError("invalid protected supply")
    if timestamp < 0 or timestamp > 2**64 - 1 - 60 * 60:
        raise GuardError("invalid activation time")
    initial_raw = protected_supply * INITIAL_BUCKET_PPB * 120
    initial_capacity, initial_remainder = divmod(initial_raw, REFILL_DENOMINATOR)
    return State(
        protected_supply=protected_supply,
        capacity=initial_capacity,
        activated_at=timestamp,
        last_updated_at=timestamp,
        capacity_remainder=initial_remainder,
        activated=True,
    )


def validate_timestamp(state: State, timestamp: int) -> None:
    if timestamp < state.activated_at or timestamp < state.last_updated_at:
        raise TimeRegression


def settle(state: State, profile: Profile, timestamp: int) -> State:
    if timestamp == state.last_updated_at:
        return state
    cursor = state.last_updated_at - state.activated_at
    target = timestamp - state.activated_at
    capacity = state.capacity
    remainder = state.capacity_remainder

    while cursor < target:
        endpoint = min(target, next_boundary(profile, cursor))
        refill_numerator = integrated_refill_numerator(profile, cursor, endpoint)
        current_raw = capacity * REFILL_DENOMINATOR + remainder
        candidate_raw = current_raw + state.protected_supply * refill_numerator
        limit_raw = state.protected_supply * bucket_limit_ppb(profile, endpoint) * 120
        capacity, remainder = divmod(min(candidate_raw, limit_raw), REFILL_DENOMINATOR)
        cursor = endpoint

    return State(
        protected_supply=state.protected_supply,
        capacity=capacity,
        activated_at=state.activated_at,
        last_updated_at=timestamp,
        capacity_remainder=remainder,
        activated=True,
    )


def next_boundary(profile: Profile, elapsed: int) -> int:
    boundaries = (300, 600, 1_200, 1_800) if profile == Profile.LAUNCH_GUARD_30 else (600, 1_200, 2_400, 3_600)
    for boundary in boundaries:
        if elapsed < boundary:
            return boundary
    return boundaries[-1]


def quote(state: State, profile: Profile, timestamp: int) -> Quote:
    if not state.activated:
        return Quote(False, 0, 0, 0, 0, 0)
    validate_timestamp(state, timestamp)
    elapsed = timestamp - state.activated_at
    if elapsed >= duration(profile):
        unlimited = 2**256 - 1
        return Quote(False, unlimited, unlimited, unlimited, 0, 0)
    preview = settle(state, profile, timestamp)
    per_swap = amount_from_ppb(state.protected_supply, per_swap_limit_ppb(profile, elapsed))
    return Quote(
        True,
        preview.capacity,
        per_swap,
        min(preview.capacity, per_swap),
        refill_rate_ppb_per_minute(profile, elapsed),
        duration(profile) - elapsed,
    )


def apply_buy(state: State, profile: Profile, timestamp: int, amount: int) -> tuple[State, bool]:
    if not state.activated:
        raise NotActivated
    validate_timestamp(state, timestamp)
    elapsed = timestamp - state.activated_at
    if elapsed >= duration(profile):
        return state, False
    state = settle(state, profile, timestamp)
    per_swap = amount_from_ppb(state.protected_supply, per_swap_limit_ppb(profile, elapsed))
    if amount > per_swap:
        raise PerSwapLimitExceeded
    if amount > state.capacity:
        raise CapacityExceeded
    return State(
        protected_supply=state.protected_supply,
        capacity=state.capacity - amount,
        activated_at=state.activated_at,
        last_updated_at=state.last_updated_at,
        capacity_remainder=state.capacity_remainder,
        activated=True,
    ), True


def apply_sell(state: State, profile: Profile, timestamp: int, amount: int) -> tuple[State, bool]:
    if not state.activated:
        raise NotActivated
    validate_timestamp(state, timestamp)
    elapsed = timestamp - state.activated_at
    if elapsed >= duration(profile):
        return state, False
    state = settle(state, profile, timestamp)
    limit_raw = state.protected_supply * bucket_limit_ppb(profile, elapsed) * 120
    current_raw = state.capacity * REFILL_DENOMINATOR + state.capacity_remainder
    capacity, remainder = divmod(min(limit_raw, current_raw + amount * REFILL_DENOMINATOR), REFILL_DENOMINATOR)
    return State(
        protected_supply=state.protected_supply,
        capacity=capacity,
        activated_at=state.activated_at,
        last_updated_at=state.last_updated_at,
        capacity_remainder=remainder,
        activated=True,
    ), True


def seconds_until_buy(state: State, profile: Profile, timestamp: int, amount: int) -> int:
    if not state.activated:
        raise NotActivated
    current = quote(state, profile, timestamp)
    if not current.active or amount <= current.max_buy:
        return 0
    low, high = 1, current.seconds_until_retirement
    while low < high:
        midpoint = low + (high - low) // 2
        future = quote(state, profile, timestamp + midpoint)
        if not future.active or amount <= future.max_buy:
            high = midpoint
        else:
            low = midpoint + 1
    return low


def assert_known_points() -> None:
    knots = {
        Profile.LAUNCH_GUARD_30: [
            (60, 15_000_000),
            (300, 35_000_000),
            (600, 67_500_000),
            (1_200, 150_000_000),
            (1_320, 169_200_000),
            (1_500, 208_125_000),
            (1_680, 259_200_000),
            (1_800, 300_000_000),
        ],
        Profile.LAUNCH_GUARD_60: [
            (120, 15_000_000),
            (600, 35_000_000),
            (1_200, 67_500_000),
            (2_400, 150_000_000),
            (2_640, 169_200_000),
            (3_000, 208_125_000),
            (3_360, 259_200_000),
            (3_600, 300_000_000),
        ],
    }
    for profile, expected in knots.items():
        for elapsed, release in expected:
            assert cumulative_release_ppb(profile, elapsed) == release

    supply = 10**24
    for profile in Profile:
        state = activate(State(), supply, 0)
        half_percent = amount_from_ppb(supply, 5_000_000)
        state, _ = apply_buy(state, profile, 0, half_percent)
        state, _ = apply_buy(state, profile, 0, half_percent)
        assert state.capacity == 0
        state, _ = apply_sell(state, profile, 0, half_percent)
        assert state.capacity == half_percent
        state, _ = apply_buy(state, profile, 0, half_percent)
        assert state.capacity == 0

    for profile, timestamp in (
        (Profile.LAUNCH_GUARD_30, 25 * 60),
        (Profile.LAUNCH_GUARD_60, 50 * 60),
    ):
        opening = activate(State(), supply, 0)
        direct = settle(opening, profile, timestamp)
        assert direct.capacity == amount_from_ppb(supply, 78_125_000)
        stepped = opening
        for minute in range(60, timestamp + 1, 60):
            stepped = settle(stepped, profile, minute)
        assert direct == stepped

    state = activate(State(), 1_000_000_003, 0)
    opening = amount_from_ppb(state.protected_supply, 5_000_000)
    state, _ = apply_buy(state, Profile.LAUNCH_GUARD_30, 0, opening)
    state, _ = apply_buy(state, Profile.LAUNCH_GUARD_30, 0, opening)
    direct, _ = apply_sell(state, Profile.LAUNCH_GUARD_30, 13, 0)
    incremental = state
    for second in range(1, 14):
        incremental, _ = apply_sell(incremental, Profile.LAUNCH_GUARD_30, second, 0)
    assert direct == incremental


def fuzz_profile(profile: Profile, steps: int, rng: random.Random) -> dict[str, int]:
    accepted_buys = rejected_buys = sells = resets = 0
    state = activate(State(), rng.randrange(MIN_PROTECTED_SUPPLY, 10**30), 0)
    timestamp = 0

    for _ in range(steps):
        if timestamp - state.activated_at >= duration(profile) or rng.random() < 0.001:
            state = activate(State(), rng.randrange(MIN_PROTECTED_SUPPLY, 10**30), 0)
            timestamp = 0
            resets += 1

        timestamp = min(duration(profile), timestamp + rng.randrange(0, 31))
        before = state
        current = quote(state, profile, timestamp)

        action = rng.random()
        if action < 0.55 and current.active:
            if rng.random() < 0.75:
                amount = rng.randrange(current.max_buy + 1) if current.max_buy else 0
            else:
                amount = current.max_buy + 1 + rng.randrange(max(1, state.protected_supply // 100))
            try:
                state, enforced = apply_buy(state, profile, timestamp, amount)
                assert enforced
                accepted_buys += 1
            except (CapacityExceeded, PerSwapLimitExceeded):
                assert state == before
                rejected_buys += 1
        elif action < 0.9 and current.active:
            amount = rng.randrange(max(1, state.protected_supply // 20))
            state, enforced = apply_sell(state, profile, timestamp, amount)
            assert enforced
            sells += 1

        current = quote(state, profile, timestamp)
        if current.active:
            elapsed = timestamp - state.activated_at
            limit = amount_from_ppb(state.protected_supply, bucket_limit_ppb(profile, elapsed))
            assert 0 <= current.available_capacity <= limit
            assert current.max_buy == min(current.available_capacity, current.per_swap_limit)
            assert 0 <= state.capacity_remainder < REFILL_DENOMINATOR
            assert current.seconds_until_retirement == duration(profile) - elapsed
        else:
            assert current.max_buy == 2**256 - 1

    return {
        "accepted_buys": accepted_buys,
        "rejected_buys": rejected_buys,
        "sells": sells,
        "resets": resets,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--steps", type=int, default=1_000_000)
    parser.add_argument("--seed", type=int, default=304)
    args = parser.parse_args()

    assert_known_points()
    rng = random.Random(args.seed)
    first = args.steps // 2
    results_30 = fuzz_profile(Profile.LAUNCH_GUARD_30, first, rng)
    results_60 = fuzz_profile(Profile.LAUNCH_GUARD_60, args.steps - first, rng)
    print(f"PASS: {args.steps:,} randomized Launch Guard transitions; seed={args.seed}")
    print(f"Launch Guard 30: {results_30}")
    print(f"Launch Guard 60: {results_60}")


if __name__ == "__main__":
    main()
