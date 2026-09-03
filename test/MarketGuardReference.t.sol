// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketGuardReferenceHarness} from "../src/MarketGuardReference.sol";

contract MarketGuardReferenceTest {
    uint256 internal constant WAD = 1e18;
    MarketGuardReferenceHarness internal harness = new MarketGuardReferenceHarness();

    function testBootstrapIsTenPercent() public view {
        require(harness.bootstrapTrustedLiquidity(1_000_000) == 100_000, "bootstrap");
    }

    function testTrustedCalibrationSchedule() public view {
        uint256 active = 1_000_000;
        uint256 trusted = harness.bootstrapTrustedLiquidity(active);
        trusted = harness.updateTrustedLiquidity(trusted, active, 60);
        require(trusted == 350_000, "one minute");
        trusted = harness.updateTrustedLiquidity(trusted, active, 60);
        require(trusted == 600_000, "two minutes");
        trusted = harness.updateTrustedLiquidity(trusted, active, 60);
        require(trusted == 850_000, "three minutes");
        trusted = harness.updateTrustedLiquidity(trusted, active, 60);
        require(trusted == active, "four minutes");
    }

    function testFeeKnownPoints() public view {
        require(harness.coreFeePips(0) == 2_500, "base");
        require(harness.coreFeePips(WAD / 64) == 5_000, "sqrt curve");
        require(harness.coreFeePips(WAD) == 10_000, "cap");
    }

    function testHalfLivesAreClose() public view {
        uint256 fast = harness.decayFastStress(WAD, 18);
        uint256 slow = uint256(harness.decaySlowPressure(int256(WAD), 75));
        require(fast > 499_999_999_999_990_000 && fast < 500_000_000_000_010_000, "fast half-life");
        require(slow > 499_999_999_999_990_000 && slow < 500_000_000_000_010_000, "slow half-life");
    }

    function testFuzzTrustedBounds(uint128 trustedRaw, uint128 activeRaw, uint32 elapsedRaw) public view {
        uint256 active = uint256(activeRaw) % 1e30;
        uint256 trusted = active == 0 ? 0 : uint256(trustedRaw) % (active + 1);
        uint256 elapsed = uint256(elapsedRaw) % 86_400;
        uint256 next = harness.updateTrustedLiquidity(trusted, active, elapsed);
        require(next <= active, "above active");
        if (active <= trusted) {
            require(next == active, "down not immediate");
        } else {
            uint256 maxGrowth = active * elapsed / 240;
            require(next <= trusted + maxGrowth, "growth rate");
            require(next >= trusted, "unexpected decrease");
        }
    }

    function testFuzzCoreFeeBounded(uint128 stressRaw) public view {
        uint256 stressWad = uint256(stressRaw) % 1e30;
        uint24 fee = harness.coreFeePips(stressWad);
        require(fee >= 2_500 && fee <= 10_000, "fee bounds");
    }

    function testFuzzMarginalFeeBounded(uint96 aRaw, uint96 widthRaw) public view {
        uint256 a = uint256(aRaw) % 1e25;
        uint256 b = a + uint256(widthRaw) % 1e25;
        uint24 fee = harness.marginalAverageFeePips(a, b);
        require(fee >= 2_500 && fee <= 10_000, "marginal bounds");
    }

    function testFuzzFastDenominatorBounds(uint128 denominatorRaw, uint128 targetRaw, uint16 elapsedRaw) public view {
        uint256 denominator = 1 + uint256(denominatorRaw) % 1e24;
        uint256 target = 1 + uint256(targetRaw) % 1e24;
        uint256 elapsed = uint256(elapsedRaw) % 300;
        uint256 next = harness.updateFastDenominator(denominator, target, elapsed);
        if (target <= denominator) require(next == target, "down not immediate");
        else require(next >= denominator && next <= target, "up bounds");
    }
}
