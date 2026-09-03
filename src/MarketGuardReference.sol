// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Standalone arithmetic/state reference for the frozen Market Guard
/// v0.38 research baseline (v0.33 shared core). This is not a Uniswap hook.
/// It deliberately isolates the recovered, testable rules from unrecovered
/// production wiring and settlement assumptions.
library MarketGuardReference {
    uint256 internal constant WAD = 1e18;
    uint24 internal constant BASE_FEE_PIPS = 2_500; // 25 bp
    uint24 internal constant CORE_CAP_PIPS = 10_000; // 100 bp
    uint24 internal constant SURCHARGE_AT_UNIT_STRESS_PIPS = 20_000; // 2.0%

    // floor(exp(-ln(2) / halfLife) * 1e18)
    uint256 internal constant FAST_DECAY_PER_SECOND_WAD = 962_223_836_894_145_152; // 18 s half-life
    uint256 internal constant SLOW_DECAY_PER_SECOND_WAD = 990_800_613_265_229_568; // 75 s half-life
    uint256 internal constant FAST_DENOM_GROWTH_PER_SECOND_WAD = 1_040_000_000_000_000_000;

    error ZeroLiquidity();
    error StressOrder();

    function bootstrapTrustedLiquidity(uint256 activeLiquidity) internal pure returns (uint256) {
        if (activeLiquidity == 0) revert ZeroLiquidity();
        return activeLiquidity / 10;
    }

    /// @dev Downward changes are immediate. Upward recognition is linear and
    /// capped at 25% of current active liquidity per minute.
    function updateTrustedLiquidity(uint256 trusted, uint256 active, uint256 elapsed) internal pure returns (uint256) {
        if (active == 0 || active <= trusted) return active;
        uint256 growth = active * elapsed / 240;
        uint256 candidate = trusted + growth;
        return candidate < active ? candidate : active;
    }

    /// @dev Direction-local fast denominator: down immediately, up at no more
    /// than approximately 4% compounded per elapsed second.
    function updateFastDenominator(uint256 denominator, uint256 target, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        if (target <= denominator) return target;
        uint256 ceiling = denominator * rpow(FAST_DENOM_GROWTH_PER_SECOND_WAD, elapsed, WAD) / WAD;
        return ceiling < target ? ceiling : target;
    }

    function decayFastStress(uint256 stressWad, uint256 elapsed) internal pure returns (uint256) {
        return stressWad * rpow(FAST_DECAY_PER_SECOND_WAD, elapsed, WAD) / WAD;
    }

    function decaySlowPressure(int256 pressureWad, uint256 elapsed) internal pure returns (int256) {
        uint256 factor = rpow(SLOW_DECAY_PER_SECOND_WAD, elapsed, WAD);
        return pressureWad * int256(factor) / int256(WAD);
    }

    function stress(uint256 normalizedTradeAmount, uint256 effectiveLiquidity) internal pure returns (uint256) {
        if (effectiveLiquidity == 0) revert ZeroLiquidity();
        return normalizedTradeAmount * WAD / effectiveLiquidity;
    }

    /// @notice 25 bp + 2.0% * sqrt(stress), hard-capped at 100 bp.
    function coreFeePips(uint256 stressWad) internal pure returns (uint24) {
        uint256 sqrtStressWad = sqrt(stressWad * WAD);
        uint256 fee = BASE_FEE_PIPS + SURCHARGE_AT_UNIT_STRESS_PIPS * sqrtStressWad / WAD;
        return uint24(fee < CORE_CAP_PIPS ? fee : CORE_CAP_PIPS);
    }

    /// @notice Average fee over a movement from stressBefore to stressAfter,
    /// using the exact cumulative integral of sqrt(stress), before integer
    /// rounding and the hard cap. The interval must be nondecreasing.
    function marginalAverageFeePips(uint256 stressBeforeWad, uint256 stressAfterWad) internal pure returns (uint24) {
        if (stressAfterWad < stressBeforeWad) revert StressOrder();
        if (stressAfterWad == stressBeforeWad) return coreFeePips(stressBeforeWad);

        uint256 p0 = sqrtPrimitiveWad(stressBeforeWad);
        uint256 p1 = sqrtPrimitiveWad(stressAfterWad);
        uint256 averageSqrtWad = (p1 - p0) * WAD / (stressAfterWad - stressBeforeWad);
        uint256 fee = BASE_FEE_PIPS + SURCHARGE_AT_UNIT_STRESS_PIPS * averageSqrtWad / WAD;
        return uint24(fee < CORE_CAP_PIPS ? fee : CORE_CAP_PIPS);
    }

    /// @dev Integral from 0 to x of sqrt(t) dt, represented in WAD.
    function sqrtPrimitiveWad(uint256 xWad) internal pure returns (uint256) {
        return 2 * xWad * sqrt(xWad * WAD) / (3 * WAD);
    }

    function rpow(uint256 x, uint256 n, uint256 scalar) internal pure returns (uint256 z) {
        if (n == 0) return scalar;
        z = n % 2 != 0 ? x : scalar;
        for (n /= 2; n != 0; n /= 2) {
            x = (x * x + scalar / 2) / scalar;
            if (n % 2 != 0) z = (z * x + scalar / 2) / scalar;
        }
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = 1 << ((log2(x) + 1) >> 1);
        for (uint256 i; i < 7; ++i) {
            z = (z + x / z) >> 1;
        }
        uint256 roundedDown = x / z;
        return z < roundedDown ? z : roundedDown;
    }

    function log2(uint256 x) internal pure returns (uint256 r) {
        if (x >> 128 > 0) {
            x >>= 128;
            r += 128;
        }
        if (x >> 64 > 0) {
            x >>= 64;
            r += 64;
        }
        if (x >> 32 > 0) {
            x >>= 32;
            r += 32;
        }
        if (x >> 16 > 0) {
            x >>= 16;
            r += 16;
        }
        if (x >> 8 > 0) {
            x >>= 8;
            r += 8;
        }
        if (x >> 4 > 0) {
            x >>= 4;
            r += 4;
        }
        if (x >> 2 > 0) {
            x >>= 2;
            r += 2;
        }
        if (x >> 1 > 0) r += 1;
    }
}

/// @notice External wrapper used only to execute the reference through an EVM.
contract MarketGuardReferenceHarness {
    function bootstrapTrustedLiquidity(uint256 active) external pure returns (uint256) {
        return MarketGuardReference.bootstrapTrustedLiquidity(active);
    }

    function updateTrustedLiquidity(uint256 trusted, uint256 active, uint256 elapsed) external pure returns (uint256) {
        return MarketGuardReference.updateTrustedLiquidity(trusted, active, elapsed);
    }

    function updateFastDenominator(uint256 denominator, uint256 target, uint256 elapsed)
        external
        pure
        returns (uint256)
    {
        return MarketGuardReference.updateFastDenominator(denominator, target, elapsed);
    }

    function decayFastStress(uint256 value, uint256 elapsed) external pure returns (uint256) {
        return MarketGuardReference.decayFastStress(value, elapsed);
    }

    function decaySlowPressure(int256 value, uint256 elapsed) external pure returns (int256) {
        return MarketGuardReference.decaySlowPressure(value, elapsed);
    }

    function coreFeePips(uint256 stressWad) external pure returns (uint24) {
        return MarketGuardReference.coreFeePips(stressWad);
    }

    function marginalAverageFeePips(uint256 beforeWad, uint256 afterWad) external pure returns (uint24) {
        return MarketGuardReference.marginalAverageFeePips(beforeWad, afterWad);
    }
}
