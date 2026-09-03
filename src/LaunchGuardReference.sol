// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Executable state-machine reference for the custom Launch Guard 30
/// v1.1 and Launch Guard 60 v0.4 profiles.
/// @dev This library deliberately contains no Uniswap imports. A production
/// hook must restrict activation to its trusted launch path, derive guarded
/// token flow from BalanceDelta, and persist one State per PoolId.
library LaunchGuardReference {
    uint256 internal constant PPB = 1_000_000_000;
    uint256 internal constant REFILL_DENOMINATOR = PPB * 120;

    uint256 internal constant INITIAL_BUCKET_PPB = 10_000_000; // 1.00%
    uint256 internal constant MIN_PROTECTED_SUPPLY = 200;

    uint32 internal constant LG30_DURATION = 30 minutes;
    uint32 internal constant LG60_DURATION = 60 minutes;

    enum Profile {
        LaunchGuard30,
        LaunchGuard60
    }

    /// @dev protectedSupply and capacity share one slot. The three timestamps /
    /// remainder fields and the activation flag share a second slot.
    struct State {
        uint128 protectedSupply;
        uint128 capacity;
        uint64 activatedAt;
        uint64 lastUpdatedAt;
        uint64 capacityRemainder;
        bool activated;
    }

    struct Quote {
        bool active;
        uint256 availableCapacity;
        uint256 perSwapLimit;
        uint256 maxBuy;
        uint32 refillRatePpbPerMinute;
        uint32 secondsUntilRetirement;
    }

    error AlreadyActivated();
    error GuardNotActivated();
    error InvalidProtectedSupply();
    error InvalidActivationTime();
    error TimeRegression();
    error InvalidInterval();
    error CapacityExceeded(uint256 requested, uint256 available);
    error PerSwapLimitExceeded(uint256 requested, uint256 limit);

    /// @notice Arms the state at the authorized launch-liquidity timestamp.
    /// @dev The caller, not this arithmetic library, is responsible for proving
    /// that activation is authorized and atomic with initial liquidity becoming
    /// usable. Swaps must remain blocked until this has been called.
    function activate(State memory state, uint256 protectedSupply, uint64 activatedAt)
        internal
        pure
        returns (State memory)
    {
        if (state.activated) revert AlreadyActivated();
        if (protectedSupply < MIN_PROTECTED_SUPPLY || protectedSupply > type(uint128).max) {
            revert InvalidProtectedSupply();
        }
        if (activatedAt > type(uint64).max - LG60_DURATION) revert InvalidActivationTime();

        state.protectedSupply = uint128(protectedSupply);
        _setRawCapacity(state, protectedSupply * INITIAL_BUCKET_PPB * 120);
        state.activatedAt = activatedAt;
        state.lastUpdatedAt = activatedAt;
        state.activated = true;
        return state;
    }

    /// @notice Returns the current non-mutating trading limits.
    /// @dev Unarmed states report zero capacity. Retired states report unlimited
    /// capacity because the Launch Guard restrictions no longer apply.
    function quote(State memory state, Profile profile, uint64 timestamp) internal pure returns (Quote memory result) {
        if (!state.activated) return result;
        _validateTimestamp(state, timestamp);

        uint32 elapsed = uint32(timestamp - state.activatedAt);
        uint32 profileDuration = duration(profile);
        if (elapsed >= profileDuration) {
            result.availableCapacity = type(uint256).max;
            result.perSwapLimit = type(uint256).max;
            result.maxBuy = type(uint256).max;
            return result;
        }

        // Internal memory arguments may alias. Copy explicitly so a read-only
        // quote cannot advance the caller's in-memory State during binary search.
        state = _copyState(state);
        state = _settle(state, profile, timestamp);
        result.active = true;
        result.availableCapacity = state.capacity;
        result.perSwapLimit = _amountFromPpb(state.protectedSupply, perSwapLimitPpb(profile, elapsed));
        result.maxBuy = result.availableCapacity < result.perSwapLimit ? result.availableCapacity : result.perSwapLimit;
        result.refillRatePpbPerMinute = uint32(refillRatePpbPerMinute(profile, elapsed));
        result.secondsUntilRetirement = profileDuration - elapsed;
    }

    /// @notice Applies an actual guarded-token output amount for a successful buy.
    /// @return next Updated state. It must be committed only after all checks pass.
    /// @return enforced False at or after retirement, when the state is unchanged.
    function applyBuy(State memory state, Profile profile, uint64 timestamp, uint256 guardedTokenOut)
        internal
        pure
        returns (State memory next, bool enforced)
    {
        if (!state.activated) revert GuardNotActivated();
        _validateTimestamp(state, timestamp);

        uint32 elapsed = uint32(timestamp - state.activatedAt);
        if (elapsed >= duration(profile)) return (state, false);

        state = _settle(state, profile, timestamp);
        uint256 swapLimit = _amountFromPpb(state.protectedSupply, perSwapLimitPpb(profile, elapsed));
        if (guardedTokenOut > swapLimit) revert PerSwapLimitExceeded(guardedTokenOut, swapLimit);
        if (guardedTokenOut > state.capacity) revert CapacityExceeded(guardedTokenOut, state.capacity);

        state.capacity = uint128(uint256(state.capacity) - guardedTokenOut);
        return (state, true);
    }

    /// @notice Credits actual guarded-token input from a sell back into capacity.
    /// @dev Crediting sells converts the mechanism from gross-buy accounting to
    /// net guarded-token outflow accounting. Credits never exceed I(t), and any
    /// surplus at a full bucket is discarded rather than banked.
    function applySell(State memory state, Profile profile, uint64 timestamp, uint256 guardedTokenIn)
        internal
        pure
        returns (State memory next, bool enforced)
    {
        if (!state.activated) revert GuardNotActivated();
        _validateTimestamp(state, timestamp);

        uint32 elapsed = uint32(timestamp - state.activatedAt);
        if (elapsed >= duration(profile)) return (state, false);

        state = _settle(state, profile, timestamp);
        uint256 limitRaw = _rawBucketLimit(state.protectedSupply, bucketLimitPpb(profile, elapsed));
        uint256 currentRaw = uint256(state.capacity) * REFILL_DENOMINATOR + state.capacityRemainder;
        uint256 headroomRaw = limitRaw - currentRaw;
        uint256 headroomTokens = (headroomRaw + REFILL_DENOMINATOR - 1) / REFILL_DENOMINATOR;
        if (guardedTokenIn >= headroomTokens) {
            _setRawCapacity(state, limitRaw);
        } else {
            state.capacity = uint128(uint256(state.capacity) + guardedTokenIn);
        }
        return (state, true);
    }

    /// @notice Earliest deterministic wait until an amount can pass both active
    /// limits, assuming no intervening swaps. Retirement always makes it legal.
    /// @dev Intended for an off-hook lens / frontend, not a swap callback.
    function secondsUntilBuy(State memory state, Profile profile, uint64 timestamp, uint256 amount)
        internal
        pure
        returns (uint32)
    {
        if (!state.activated) revert GuardNotActivated();
        _validateTimestamp(state, timestamp);

        Quote memory current = quote(state, profile, timestamp);
        if (!current.active || amount <= current.maxBuy) return 0;

        uint32 low = 1;
        uint32 high = current.secondsUntilRetirement;
        while (low < high) {
            uint32 midpoint = low + (high - low) / 2;
            Quote memory future = quote(state, profile, timestamp + midpoint);
            if (!future.active || amount <= future.maxBuy) high = midpoint;
            else low = midpoint + 1;
        }
        return low;
    }

    function duration(Profile profile) internal pure returns (uint32) {
        return profile == Profile.LaunchGuard30 ? LG30_DURATION : LG60_DURATION;
    }

    /// @notice I(t), in parts per billion of protected supply.
    function bucketLimitPpb(Profile profile, uint256 elapsed) internal pure returns (uint256) {
        uint256 profileDuration = duration(profile);
        if (elapsed > profileDuration) elapsed = profileDuration;

        if (profile == Profile.LaunchGuard30) {
            if (elapsed <= 5 minutes) return 10_000_000;
            if (elapsed <= 10 minutes) return _lerp(10_000_000, 12_500_000, elapsed - 5 minutes, 5 minutes);
            if (elapsed <= 20 minutes) return _lerp(12_500_000, 20_000_000, elapsed - 10 minutes, 10 minutes);
            return _lerp(20_000_000, 150_000_000, elapsed - 20 minutes, 10 minutes);
        }

        if (elapsed <= 10 minutes) return 10_000_000;
        if (elapsed <= 20 minutes) return _lerp(10_000_000, 12_500_000, elapsed - 10 minutes, 10 minutes);
        if (elapsed <= 40 minutes) return _lerp(12_500_000, 20_000_000, elapsed - 20 minutes, 20 minutes);
        return _lerp(20_000_000, 150_000_000, elapsed - 40 minutes, 20 minutes);
    }

    /// @notice S(t), in parts per billion of protected supply.
    function perSwapLimitPpb(Profile profile, uint256 elapsed) internal pure returns (uint256) {
        uint256 profileDuration = duration(profile);
        if (elapsed > profileDuration) elapsed = profileDuration;

        if (profile == Profile.LaunchGuard30) {
            if (elapsed <= 5 minutes) return 5_000_000;
            if (elapsed <= 10 minutes) return _lerp(5_000_000, 7_500_000, elapsed - 5 minutes, 5 minutes);
            if (elapsed <= 20 minutes) return _lerp(7_500_000, 10_000_000, elapsed - 10 minutes, 10 minutes);
            return _lerp(10_000_000, 100_000_000, elapsed - 20 minutes, 10 minutes);
        }

        if (elapsed <= 10 minutes) return 5_000_000;
        if (elapsed <= 20 minutes) return _lerp(5_000_000, 7_500_000, elapsed - 10 minutes, 10 minutes);
        if (elapsed <= 40 minutes) return _lerp(7_500_000, 10_000_000, elapsed - 20 minutes, 20 minutes);
        return _lerp(10_000_000, 100_000_000, elapsed - 40 minutes, 20 minutes);
    }

    /// @notice r(t), in parts per billion of protected supply per minute.
    function refillRatePpbPerMinute(Profile profile, uint256 elapsed) internal pure returns (uint256) {
        uint256 profileDuration = duration(profile);
        if (elapsed > profileDuration) elapsed = profileDuration;

        if (profile == Profile.LaunchGuard30) {
            if (elapsed < 5 minutes) return 5_000_000;
            if (elapsed < 10 minutes) return 6_500_000;
            if (elapsed < 20 minutes) return 8_250_000;
            return _lerp(8_250_000, 21_750_000, elapsed - 20 minutes, 10 minutes);
        }

        if (elapsed < 10 minutes) return 2_500_000;
        if (elapsed < 20 minutes) return 3_250_000;
        if (elapsed < 40 minutes) return 4_125_000;
        return _lerp(4_125_000, 10_875_000, elapsed - 40 minutes, 20 minutes);
    }

    /// @notice Exact integral of r(t) over [fromElapsed, toElapsed], scaled by
    /// 120. The common denominator lets repeated lazy updates preserve fractional
    /// token credits with State.capacityRemainder and eliminates path dependence.
    function integratedRefillNumerator(Profile profile, uint256 fromElapsed, uint256 toElapsed)
        internal
        pure
        returns (uint256)
    {
        if (toElapsed < fromElapsed) revert InvalidInterval();
        uint256 profileDuration = duration(profile);
        if (fromElapsed > profileDuration) fromElapsed = profileDuration;
        if (toElapsed > profileDuration) toElapsed = profileDuration;
        return _cumulativeRefillNumerator(profile, toElapsed) - _cumulativeRefillNumerator(profile, fromElapsed);
    }

    /// @notice Saturated cumulative buy envelope: initial 1% plus integrated r.
    function cumulativeReleasePpb(Profile profile, uint256 elapsed) internal pure returns (uint256) {
        uint256 profileDuration = duration(profile);
        if (elapsed > profileDuration) elapsed = profileDuration;
        return INITIAL_BUCKET_PPB + _cumulativeRefillNumerator(profile, elapsed) / 120;
    }

    function _settle(State memory state, Profile profile, uint64 timestamp) private pure returns (State memory) {
        if (timestamp == state.lastUpdatedAt) return state;

        uint256 cursor = state.lastUpdatedAt - state.activatedAt;
        uint256 target = timestamp - state.activatedAt;

        // Cap at every schedule boundary. A single final-time min() would bank
        // refill earned while an earlier, lower I(t) was already full and could
        // overcredit the widening tail. There are at most four iterations.
        while (cursor < target) {
            uint256 endpoint = _nextBoundary(profile, cursor);
            if (endpoint > target) endpoint = target;

            uint256 refillNumerator = integratedRefillNumerator(profile, cursor, endpoint);
            uint256 currentRaw = uint256(state.capacity) * REFILL_DENOMINATOR + state.capacityRemainder;
            uint256 candidateRaw = currentRaw + uint256(state.protectedSupply) * refillNumerator;
            uint256 limitRaw = _rawBucketLimit(state.protectedSupply, bucketLimitPpb(profile, endpoint));
            _setRawCapacity(state, candidateRaw < limitRaw ? candidateRaw : limitRaw);
            cursor = endpoint;
        }
        state.lastUpdatedAt = timestamp;
        return state;
    }

    function _nextBoundary(Profile profile, uint256 elapsed) private pure returns (uint256) {
        if (profile == Profile.LaunchGuard30) {
            if (elapsed < 5 minutes) return 5 minutes;
            if (elapsed < 10 minutes) return 10 minutes;
            if (elapsed < 20 minutes) return 20 minutes;
            return 30 minutes;
        }
        if (elapsed < 10 minutes) return 10 minutes;
        if (elapsed < 20 minutes) return 20 minutes;
        if (elapsed < 40 minutes) return 40 minutes;
        return 60 minutes;
    }

    function _cumulativeRefillNumerator(Profile profile, uint256 elapsed) private pure returns (uint256 result) {
        return profile == Profile.LaunchGuard30
            ? _cumulativeRefillNumerator30(elapsed)
            : _cumulativeRefillNumerator60(elapsed);
    }

    function _cumulativeRefillNumerator30(uint256 elapsed) private pure returns (uint256 result) {
        uint256 first = elapsed < 5 minutes ? elapsed : 5 minutes;
        result = 2 * 5_000_000 * first;
        if (elapsed <= 5 minutes) return result;

        uint256 second = elapsed < 10 minutes ? elapsed - 5 minutes : 5 minutes;
        result += 2 * 6_500_000 * second;
        if (elapsed <= 10 minutes) return result;

        uint256 third = elapsed < 20 minutes ? elapsed - 10 minutes : 10 minutes;
        result += 2 * 8_250_000 * third;
        if (elapsed <= 20 minutes) return result;

        uint256 tail = elapsed - 20 minutes;
        return result + 2 * 8_250_000 * tail + 22_500 * tail * tail;
    }

    function _cumulativeRefillNumerator60(uint256 elapsed) private pure returns (uint256 result) {
        uint256 first = elapsed < 10 minutes ? elapsed : 10 minutes;
        result = 2 * 2_500_000 * first;
        if (elapsed <= 10 minutes) return result;

        uint256 second = elapsed < 20 minutes ? elapsed - 10 minutes : 10 minutes;
        result += 2 * 3_250_000 * second;
        if (elapsed <= 20 minutes) return result;

        uint256 third = elapsed < 40 minutes ? elapsed - 20 minutes : 20 minutes;
        result += 2 * 4_125_000 * third;
        if (elapsed <= 40 minutes) return result;

        uint256 tail = elapsed - 40 minutes;
        return result + 2 * 4_125_000 * tail + 5_625 * tail * tail;
    }

    function _validateTimestamp(State memory state, uint64 timestamp) private pure {
        if (timestamp < state.activatedAt || timestamp < state.lastUpdatedAt) revert TimeRegression();
    }

    function _copyState(State memory state) private pure returns (State memory) {
        return State({
            protectedSupply: state.protectedSupply,
            capacity: state.capacity,
            activatedAt: state.activatedAt,
            lastUpdatedAt: state.lastUpdatedAt,
            capacityRemainder: state.capacityRemainder,
            activated: state.activated
        });
    }

    function _amountFromPpb(uint256 supply, uint256 amountPpb) private pure returns (uint256) {
        return supply * amountPpb / PPB;
    }

    function _rawBucketLimit(uint256 supply, uint256 amountPpb) private pure returns (uint256) {
        return supply * amountPpb * 120;
    }

    function _setRawCapacity(State memory state, uint256 rawCapacity) private pure {
        state.capacity = uint128(rawCapacity / REFILL_DENOMINATOR);
        state.capacityRemainder = uint64(rawCapacity % REFILL_DENOMINATOR);
    }

    function _lerp(uint256 start, uint256 end, uint256 offset, uint256 width) private pure returns (uint256) {
        return start + (end - start) * offset / width;
    }
}

/// @notice ABI wrapper used to execute the Launch Guard reference through an EVM.
contract LaunchGuardReferenceHarness {
    function activate(LaunchGuardReference.State memory state, uint256 protectedSupply, uint64 activatedAt)
        external
        pure
        returns (LaunchGuardReference.State memory)
    {
        return LaunchGuardReference.activate(state, protectedSupply, activatedAt);
    }

    function quote(LaunchGuardReference.State memory state, LaunchGuardReference.Profile profile, uint64 timestamp)
        external
        pure
        returns (LaunchGuardReference.Quote memory)
    {
        return LaunchGuardReference.quote(state, profile, timestamp);
    }

    function applyBuy(
        LaunchGuardReference.State memory state,
        LaunchGuardReference.Profile profile,
        uint64 timestamp,
        uint256 amount
    ) external pure returns (LaunchGuardReference.State memory, bool) {
        return LaunchGuardReference.applyBuy(state, profile, timestamp, amount);
    }

    function applySell(
        LaunchGuardReference.State memory state,
        LaunchGuardReference.Profile profile,
        uint64 timestamp,
        uint256 amount
    ) external pure returns (LaunchGuardReference.State memory, bool) {
        return LaunchGuardReference.applySell(state, profile, timestamp, amount);
    }

    function secondsUntilBuy(
        LaunchGuardReference.State memory state,
        LaunchGuardReference.Profile profile,
        uint64 timestamp,
        uint256 amount
    ) external pure returns (uint32) {
        return LaunchGuardReference.secondsUntilBuy(state, profile, timestamp, amount);
    }

    function duration(LaunchGuardReference.Profile profile) external pure returns (uint32) {
        return LaunchGuardReference.duration(profile);
    }

    function schedule(LaunchGuardReference.Profile profile, uint256 elapsed)
        external
        pure
        returns (uint256 bucketPpb, uint256 refillPpbPerMinute, uint256 perSwapPpb)
    {
        return (
            LaunchGuardReference.bucketLimitPpb(profile, elapsed),
            LaunchGuardReference.refillRatePpbPerMinute(profile, elapsed),
            LaunchGuardReference.perSwapLimitPpb(profile, elapsed)
        );
    }

    function integratedRefillNumerator(LaunchGuardReference.Profile profile, uint256 fromElapsed, uint256 toElapsed)
        external
        pure
        returns (uint256)
    {
        return LaunchGuardReference.integratedRefillNumerator(profile, fromElapsed, toElapsed);
    }

    function cumulativeReleasePpb(LaunchGuardReference.Profile profile, uint256 elapsed)
        external
        pure
        returns (uint256)
    {
        return LaunchGuardReference.cumulativeReleasePpb(profile, elapsed);
    }
}
