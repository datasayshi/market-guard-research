// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchGuardReference, LaunchGuardReferenceHarness} from "../src/LaunchGuardReference.sol";

contract StatefulLaunchGuardHarness {
    LaunchGuardReference.State private state;
    LaunchGuardReference.Profile public immutable profile;

    constructor(LaunchGuardReference.Profile selectedProfile) {
        profile = selectedProfile;
    }

    function activate(uint256 protectedSupply, uint64 timestamp) external {
        state = LaunchGuardReference.activate(state, protectedSupply, timestamp);
    }

    function buy(uint64 timestamp, uint256 amount) external returns (bool enforced) {
        (state, enforced) = LaunchGuardReference.applyBuy(state, profile, timestamp, amount);
    }

    function sell(uint64 timestamp, uint256 amount) external returns (bool enforced) {
        (state, enforced) = LaunchGuardReference.applySell(state, profile, timestamp, amount);
    }

    function current(uint64 timestamp) external view returns (LaunchGuardReference.Quote memory) {
        return LaunchGuardReference.quote(state, profile, timestamp);
    }

    function waitFor(uint64 timestamp, uint256 amount) external view returns (uint32) {
        return LaunchGuardReference.secondsUntilBuy(state, profile, timestamp, amount);
    }

    function rawState() external view returns (LaunchGuardReference.State memory) {
        return state;
    }
}

contract LaunchGuardReferenceTest {
    uint256 internal constant PPB = 1_000_000_000;
    uint256 internal constant SUPPLY = 1_000_000_000_000;

    LaunchGuardReferenceHarness internal harness = new LaunchGuardReferenceHarness();

    function testLaunchGuard30ScheduleKnots() public view {
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard30, 0, 10_000_000, 5_000_000, 5_000_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard30, 5 minutes, 10_000_000, 6_500_000, 5_000_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard30, 10 minutes, 12_500_000, 8_250_000, 7_500_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard30, 20 minutes, 20_000_000, 8_250_000, 10_000_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard30, 30 minutes, 150_000_000, 21_750_000, 100_000_000);
    }

    function testLaunchGuard60ScheduleKnots() public view {
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard60, 0, 10_000_000, 2_500_000, 5_000_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard60, 10 minutes, 10_000_000, 3_250_000, 5_000_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard60, 20 minutes, 12_500_000, 4_125_000, 7_500_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard60, 40 minutes, 20_000_000, 4_125_000, 10_000_000);
        _assertSchedule(LaunchGuardReference.Profile.LaunchGuard60, 60 minutes, 150_000_000, 10_875_000, 100_000_000);
    }

    function testLaunchGuard30ReleaseKnots() public view {
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 1 minutes, 15_000_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 5 minutes, 35_000_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 10 minutes, 67_500_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 20 minutes, 150_000_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 22 minutes, 169_200_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 25 minutes, 208_125_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 28 minutes, 259_200_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard30, 30 minutes, 300_000_000);
    }

    function testLaunchGuard60ReleaseKnots() public view {
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 2 minutes, 15_000_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 10 minutes, 35_000_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 20 minutes, 67_500_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 40 minutes, 150_000_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 44 minutes, 169_200_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 50 minutes, 208_125_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 56 minutes, 259_200_000);
        _assertRelease(LaunchGuardReference.Profile.LaunchGuard60, 60 minutes, 300_000_000);
    }

    function testSwapsBlockedUntilActivation() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        (bool buyOk,) = address(stateful).call(abi.encodeCall(stateful.buy, (0, 1)));
        (bool sellOk,) = address(stateful).call(abi.encodeCall(stateful.sell, (0, 1)));
        require(!buyOk && !sellOk, "unarmed swap passed");
    }

    function testActivationUsesExplicitProtectedSupplyAndCannotRepeat() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        stateful.activate(SUPPLY, 100);
        LaunchGuardReference.State memory state = stateful.rawState();
        require(state.protectedSupply == SUPPLY, "protected supply");
        require(state.capacity == SUPPLY / 100, "initial bucket");
        require(state.activatedAt == 100 && state.lastUpdatedAt == 100, "activation time");

        (bool repeated,) = address(stateful).call(abi.encodeCall(stateful.activate, (SUPPLY, 100)));
        require(!repeated, "reactivated");
    }

    function testNetFlowCreditDefeatsRoundTripCapacityGrief() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        stateful.activate(SUPPLY, 0);
        uint256 halfPercent = SUPPLY * 5_000_000 / PPB;

        require(stateful.buy(0, halfPercent), "first buy not enforced");
        require(stateful.buy(0, halfPercent), "second buy not enforced");
        require(stateful.current(0).availableCapacity == 0, "bucket not empty");

        require(stateful.sell(0, halfPercent), "sell not enforced");
        require(stateful.current(0).availableCapacity == halfPercent, "sell not credited");
        require(stateful.buy(0, halfPercent), "honest buy blocked");
        require(stateful.current(0).availableCapacity == 0, "round trip accounting");
    }

    function testSellCreditCannotExceedCurrentBucketLimit() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        stateful.activate(SUPPLY, 0);
        stateful.buy(0, SUPPLY * 5_000_000 / PPB);
        stateful.sell(0, type(uint256).max);
        require(stateful.current(0).availableCapacity == SUPPLY / 100, "sell overcredit");
    }

    function testRejectedBuyDoesNotMutateState() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        stateful.activate(SUPPLY, 0);
        LaunchGuardReference.State memory beforeState = stateful.rawState();

        uint256 overPerSwap = SUPPLY * 5_000_000 / PPB + 1;
        (bool ok,) = address(stateful).call(abi.encodeCall(stateful.buy, (0, overPerSwap)));
        require(!ok, "oversized buy passed");

        LaunchGuardReference.State memory afterState = stateful.rawState();
        require(keccak256(abi.encode(beforeState)) == keccak256(abi.encode(afterState)), "failed buy mutated");
    }

    function testSameTimestampCreatesNoRefill() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        stateful.activate(SUPPLY, 0);
        uint256 halfPercent = SUPPLY * 5_000_000 / PPB;
        stateful.buy(0, halfPercent);
        stateful.buy(0, halfPercent);
        require(stateful.current(0).availableCapacity == 0, "same-time refill");
    }

    function testFractionalRefillCarryMakesUpdateFrequencyNeutral() public view {
        uint256 unevenSupply = 1_000_000_003;
        LaunchGuardReference.State memory empty;
        LaunchGuardReference.State memory direct = harness.activate(empty, unevenSupply, 0);
        LaunchGuardReference.State memory incremental = direct;
        uint256 halfPercent = unevenSupply * 5_000_000 / PPB;

        (direct,) = harness.applyBuy(direct, LaunchGuardReference.Profile.LaunchGuard30, 0, halfPercent);
        (direct,) = harness.applyBuy(direct, LaunchGuardReference.Profile.LaunchGuard30, 0, halfPercent);
        incremental = direct;

        (direct,) = harness.applySell(direct, LaunchGuardReference.Profile.LaunchGuard30, 13, 0);
        for (uint64 second = 1; second <= 13; ++second) {
            (incremental,) = harness.applySell(incremental, LaunchGuardReference.Profile.LaunchGuard30, second, 0);
        }

        require(direct.capacity == incremental.capacity, "path-dependent capacity");
        require(direct.capacityRemainder == incremental.capacityRemainder, "path-dependent remainder");
    }

    function testScheduleBoundaryCapsPreventLazyTailOvercredit() public view {
        LaunchGuardReference.State memory state30;
        state30 = harness.activate(state30, SUPPLY, 0);
        LaunchGuardReference.Quote memory minute25 =
            harness.quote(state30, LaunchGuardReference.Profile.LaunchGuard30, 25 minutes);
        // I(25m) is 8.5%, but only 2% was bankable at 20m and the first five
        // tail minutes refill 5.8125%. Earlier surplus must remain discarded.
        require(minute25.availableCapacity == SUPPLY * 78_125_000 / PPB, "LG30 tail overcredit");

        LaunchGuardReference.State memory state60;
        state60 = harness.activate(state60, SUPPLY, 0);
        LaunchGuardReference.Quote memory minute50 =
            harness.quote(state60, LaunchGuardReference.Profile.LaunchGuard60, 50 minutes);
        require(minute50.availableCapacity == SUPPLY * 78_125_000 / PPB, "LG60 tail overcredit");
    }

    function testCrossBoundaryUpdateFrequencyNeutral() public view {
        LaunchGuardReference.State memory state;
        state = harness.activate(state, SUPPLY, 0);

        LaunchGuardReference.State memory direct30;
        (direct30,) = harness.applySell(state, LaunchGuardReference.Profile.LaunchGuard30, 25 minutes, 0);
        LaunchGuardReference.State memory stepped30 = state;
        for (uint64 timestamp = 1 minutes; timestamp <= 25 minutes; timestamp += 1 minutes) {
            (stepped30,) = harness.applySell(stepped30, LaunchGuardReference.Profile.LaunchGuard30, timestamp, 0);
        }
        require(keccak256(abi.encode(direct30)) == keccak256(abi.encode(stepped30)), "LG30 update path");

        LaunchGuardReference.State memory direct60;
        (direct60,) = harness.applySell(state, LaunchGuardReference.Profile.LaunchGuard60, 50 minutes, 0);
        LaunchGuardReference.State memory stepped60 = state;
        for (uint64 timestamp = 1 minutes; timestamp <= 50 minutes; timestamp += 1 minutes) {
            (stepped60,) = harness.applySell(stepped60, LaunchGuardReference.Profile.LaunchGuard60, timestamp, 0);
        }
        require(keccak256(abi.encode(direct60)) == keccak256(abi.encode(stepped60)), "LG60 update path");
    }

    function testQuoteAndWaitHelper() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        stateful.activate(SUPPLY, 0);
        LaunchGuardReference.Quote memory opening = stateful.current(0);
        require(opening.active, "opening inactive");
        require(opening.availableCapacity == SUPPLY / 100, "opening capacity");
        require(opening.maxBuy == SUPPLY / 200, "opening max buy");
        require(opening.secondsUntilRetirement == 30 minutes, "retirement countdown");

        require(stateful.waitFor(0, SUPPLY / 100) == 20 minutes, "one-percent wait");
        require(stateful.waitFor(0, SUPPLY / 5) == 30 minutes, "retirement wait");
    }

    function testRetiresExactlyAtProfileBoundary() public {
        StatefulLaunchGuardHarness guard30 = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        guard30.activate(SUPPLY, 1_000);
        require(guard30.current(1_000 + 30 minutes - 1).active, "retired early");
        LaunchGuardReference.Quote memory retired = guard30.current(1_000 + 30 minutes);
        require(!retired.active && retired.maxBuy == type(uint256).max, "not retired");
        require(!guard30.buy(1_000 + 30 minutes, type(uint256).max), "retired buy enforced");
    }

    function testTimeRegressionRejected() public {
        StatefulLaunchGuardHarness stateful = new StatefulLaunchGuardHarness(LaunchGuardReference.Profile.LaunchGuard30);
        stateful.activate(SUPPLY, 100);
        (bool ok,) = address(stateful).call(abi.encodeCall(stateful.current, (99)));
        require(!ok, "time regression passed");
    }

    function testFuzzScheduleIsMonotone(uint16 firstRaw, uint16 secondRaw, bool useSixty) public view {
        LaunchGuardReference.Profile profile =
            useSixty ? LaunchGuardReference.Profile.LaunchGuard60 : LaunchGuardReference.Profile.LaunchGuard30;
        uint256 profileDuration = harness.duration(profile);
        uint256 first = uint256(firstRaw) % (profileDuration + 1);
        uint256 second = uint256(secondRaw) % (profileDuration + 1);
        if (first > second) (first, second) = (second, first);

        (uint256 firstI,, uint256 firstS) = harness.schedule(profile, first);
        (uint256 secondI,, uint256 secondS) = harness.schedule(profile, second);
        require(firstI <= secondI, "I decreased");
        require(firstS <= secondS, "S decreased");
        require(
            harness.cumulativeReleasePpb(profile, first) <= harness.cumulativeReleasePpb(profile, second),
            "release decreased"
        );
    }

    function testFuzzRefillIntegralIsAdditive(uint16 aRaw, uint16 bRaw, uint16 cRaw, bool useSixty) public view {
        LaunchGuardReference.Profile profile =
            useSixty ? LaunchGuardReference.Profile.LaunchGuard60 : LaunchGuardReference.Profile.LaunchGuard30;
        uint256 profileDuration = harness.duration(profile);
        uint256 a = uint256(aRaw) % (profileDuration + 1);
        uint256 b = uint256(bRaw) % (profileDuration + 1);
        uint256 c = uint256(cRaw) % (profileDuration + 1);
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);

        uint256 whole = harness.integratedRefillNumerator(profile, a, c);
        uint256 pieces =
            harness.integratedRefillNumerator(profile, a, b) + harness.integratedRefillNumerator(profile, b, c);
        require(whole == pieces, "non-additive integral");
    }

    function testFuzzUpdateFrequencyNeutral(
        uint128 supplyRaw,
        uint16 elapsedRaw,
        uint16 splitRaw,
        uint128 openingBuyRaw,
        bool useSixty
    ) public view {
        LaunchGuardReference.Profile profile = useSixty
            ? LaunchGuardReference.Profile.LaunchGuard60
            : LaunchGuardReference.Profile.LaunchGuard30;
        uint256 supply = 200 + uint256(supplyRaw) % (uint256(type(uint128).max) - 199);
        uint64 target = uint64(uint256(elapsedRaw) % harness.duration(profile));
        uint64 split = target == 0 ? 0 : uint64(uint256(splitRaw) % (uint256(target) + 1));

        LaunchGuardReference.State memory opening;
        opening = harness.activate(opening, supply, 0);
        LaunchGuardReference.Quote memory openingQuote = harness.quote(opening, profile, 0);
        uint256 openingBuy = openingQuote.maxBuy == 0 ? 0 : uint256(openingBuyRaw) % (openingQuote.maxBuy + 1);
        (opening,) = harness.applyBuy(opening, profile, 0, openingBuy);

        LaunchGuardReference.State memory direct;
        (direct,) = harness.applySell(opening, profile, target, 0);
        LaunchGuardReference.State memory stepped;
        (stepped,) = harness.applySell(opening, profile, split, 0);
        (stepped,) = harness.applySell(stepped, profile, target, 0);

        require(keccak256(abi.encode(direct)) == keccak256(abi.encode(stepped)), "update frequency changed state");
    }

    function testFuzzSuccessfulTransitionStaysBounded(
        uint128 supplyRaw,
        uint16 elapsedRaw,
        uint128 amountRaw,
        bool isSell,
        bool useSixty
    ) public view {
        LaunchGuardReference.Profile profile = useSixty
            ? LaunchGuardReference.Profile.LaunchGuard60
            : LaunchGuardReference.Profile.LaunchGuard30;
        uint256 supply = 200 + uint256(supplyRaw) % (uint256(type(uint128).max) - 199);
        uint64 elapsed = uint64(uint256(elapsedRaw) % harness.duration(profile));
        LaunchGuardReference.State memory state;
        state = harness.activate(state, supply, 0);
        LaunchGuardReference.Quote memory beforeQuote = harness.quote(state, profile, elapsed);

        if (isSell) {
            (state,) = harness.applySell(state, profile, elapsed, amountRaw);
        } else {
            uint256 amount = beforeQuote.maxBuy == 0 ? 0 : uint256(amountRaw) % (beforeQuote.maxBuy + 1);
            (state,) = harness.applyBuy(state, profile, elapsed, amount);
        }

        LaunchGuardReference.Quote memory afterQuote = harness.quote(state, profile, elapsed);
        (uint256 bucketPpb,,) = harness.schedule(profile, elapsed);
        uint256 bucketAmount = supply * bucketPpb / PPB;
        require(afterQuote.availableCapacity <= bucketAmount, "capacity above I");
        require(afterQuote.maxBuy <= afterQuote.availableCapacity, "max above capacity");
        require(afterQuote.maxBuy <= afterQuote.perSwapLimit, "max above S");
        require(state.capacityRemainder < PPB * 120, "bad remainder");
    }

    function _assertSchedule(
        LaunchGuardReference.Profile profile,
        uint256 elapsed,
        uint256 expectedI,
        uint256 expectedR,
        uint256 expectedS
    ) private view {
        (uint256 actualI, uint256 actualR, uint256 actualS) = harness.schedule(profile, elapsed);
        require(actualI == expectedI, "I knot");
        require(actualR == expectedR, "r knot");
        require(actualS == expectedS, "S knot");
    }

    function _assertRelease(LaunchGuardReference.Profile profile, uint256 elapsed, uint256 expected) private view {
        require(harness.cumulativeReleasePpb(profile, elapsed) == expected, "release knot");
    }
}
