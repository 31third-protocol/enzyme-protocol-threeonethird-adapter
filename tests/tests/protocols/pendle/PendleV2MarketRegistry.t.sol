// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {UnitTest} from "tests/bases/UnitTest.sol";
import {IPendleV2Market} from "tests/interfaces/external/IPendleV2Market.sol";
import {IPendleV2PyYtLpOracle} from "tests/interfaces/external/IPendleV2PyYtLpOracle.sol";
import {IPendleV2MarketRegistry} from "tests/interfaces/internal/IPendleV2MarketRegistry.sol";
import {PendleV2Utils} from "./PendleV2Utils.sol";

contract PendleV2MarketRegistryTest is UnitTest, PendleV2Utils {
    event MarketForUserUpdated(address indexed user, address indexed marketAddress, uint32 duration);
    event PtForUserUpdated(address indexed user, address indexed ptAddress, address indexed marketAddress);

    IPendleV2MarketRegistry registry;
    address mockPendleOracleAddress = makeAddr("MockPendleOracle");
    address mockMarketAddress = makeAddr("MockMarket");
    address mockMarketAddress2 = makeAddr("MockMarket2");
    address mockPtAddress = makeAddr("MockPT");

    function setUp() public {
        // Set the same mock PT on both mock Markets
        vm.mockCall({
            callee: mockMarketAddress,
            data: abi.encodeWithSelector(IPendleV2Market.readTokens.selector),
            returnData: abi.encode(address(0), mockPtAddress, address(0))
        });
        vm.mockCall({
            callee: mockMarketAddress2,
            data: abi.encodeWithSelector(IPendleV2Market.readTokens.selector),
            returnData: abi.encode(address(0), mockPtAddress, address(0))
        });

        // Set the mock PendlePtAndLpOracle to return a valid oracle state for any inputs
        __updateOracleState({increaseCardinalityRequired: false, oldestObservationSatisfied: true});

        // Deploy the registry with a mock oracle
        registry = __deployPendleV2MarketRegistry({_pendleOracleAddress: mockPendleOracleAddress});
    }

    // MISC HELPERS

    function __updateOracleState(bool increaseCardinalityRequired, bool oldestObservationSatisfied) internal {
        vm.mockCall({
            callee: mockPendleOracleAddress,
            data: abi.encodeWithSelector(IPendleV2PyYtLpOracle.getOracleState.selector),
            returnData: abi.encode(increaseCardinalityRequired, false, oldestObservationSatisfied)
        });
    }

    // TESTS

    function test_updateMarketsForCaller_failsWithInsufficientOracleState() public {
        // Define an arbitrary market input
        IPendleV2MarketRegistry.UpdateMarketInput[] memory updateMarketInputs =
            __encodePendleV2MarketRegistryUpdate({_marketAddress: mockMarketAddress, _duration: 1});

        // Set the oracle to return a bad increaseCardinalityRequired only
        __updateOracleState({increaseCardinalityRequired: true, oldestObservationSatisfied: true});

        // Should fail with the expected error values
        vm.expectRevert(abi.encodeWithSelector(IPendleV2MarketRegistry.InsufficientOracleState.selector, true, true));
        registry.updateMarketsForCaller({_updateMarketInputs: updateMarketInputs, _skipValidation: false});

        // Set the oracle to return a bad oldestObservationSatisfied only
        __updateOracleState({increaseCardinalityRequired: false, oldestObservationSatisfied: false});

        // Should fail with the expected error values
        vm.expectRevert(abi.encodeWithSelector(IPendleV2MarketRegistry.InsufficientOracleState.selector, false, false));
        registry.updateMarketsForCaller({_updateMarketInputs: updateMarketInputs, _skipValidation: false});

        // Set the oracle to return good values again, and the call should succeed
        __updateOracleState({increaseCardinalityRequired: false, oldestObservationSatisfied: true});
        registry.updateMarketsForCaller({_updateMarketInputs: updateMarketInputs, _skipValidation: false});
    }

    function test_updateMarketsForCaller_successWithRemovingMarketDuration() public {
        address marketAddress = mockMarketAddress;
        uint32 duration = 123;

        // Set market duration
        __test_updateMarketsForCaller_success({
            _marketAddress: marketAddress,
            _duration: duration,
            _skipValidation: false,
            _expectedLinkedMarketForPt: marketAddress
        });

        // Remove market duration
        __test_updateMarketsForCaller_success({
            _marketAddress: marketAddress,
            _duration: 0,
            _skipValidation: false,
            _expectedLinkedMarketForPt: address(0)
        });
    }

    function test_updateMarketsForCaller_successWithMultipleMarketsForPt() public {
        address marketAddressA = mockMarketAddress;
        address marketAddressB = mockMarketAddress2;
        uint32 durationA = 123;
        uint32 durationB = 456;

        // Set MarketA duration (PT linked to MarketA)
        __test_updateMarketsForCaller_success({
            _marketAddress: marketAddressA,
            _duration: durationA,
            _skipValidation: false,
            _expectedLinkedMarketForPt: marketAddressA
        });

        // Set MarketB duration (PT linked to MarketB)
        __test_updateMarketsForCaller_success({
            _marketAddress: marketAddressB,
            _duration: durationB,
            _skipValidation: false,
            _expectedLinkedMarketForPt: marketAddressB
        });

        // Remove MarketA duration (PT still linked to MarketB)
        __test_updateMarketsForCaller_success({
            _marketAddress: marketAddressA,
            _duration: 0,
            _skipValidation: false,
            _expectedLinkedMarketForPt: marketAddressB
        });

        // Remove MarketB duration (PT unlinked)
        __test_updateMarketsForCaller_success({
            _marketAddress: marketAddressB,
            _duration: 0,
            _skipValidation: false,
            _expectedLinkedMarketForPt: address(0)
        });
    }

    function test_updateMarketsForCaller_successWithSkipValidation() public {
        address marketAddress = mockMarketAddress;

        // Set the oracle to return a bad increaseCardinalityRequired
        __updateOracleState({increaseCardinalityRequired: true, oldestObservationSatisfied: true});

        // Should succeed with skipValidation
        __test_updateMarketsForCaller_success({
            _marketAddress: marketAddress,
            _duration: 123,
            _skipValidation: true,
            _expectedLinkedMarketForPt: marketAddress
        });
    }

    function __test_updateMarketsForCaller_success(
        address _marketAddress,
        uint32 _duration,
        bool _skipValidation,
        address _expectedLinkedMarketForPt
    ) internal {
        address caller = makeAddr("Caller");
        address ptAddress = mockPtAddress;

        IPendleV2MarketRegistry.UpdateMarketInput[] memory updateMarketInputs =
            __encodePendleV2MarketRegistryUpdate({_marketAddress: _marketAddress, _duration: _duration});

        // PT link should be updated if:
        // A. _duration > 0, and the market is not its previous market
        // B. _duration == 0, and the PT is linked to the market
        bool prevLinkToMarket =
            _marketAddress == registry.getPtOracleMarketForUser({_user: caller, _ptAddress: ptAddress});
        bool expectPtLinkUpdate = (_duration > 0 && !prevLinkToMarket) || (_duration == 0 && prevLinkToMarket);

        // Pre-assert the expected events
        expectEmit(address(registry));
        emit MarketForUserUpdated(caller, _marketAddress, _duration);

        if (expectPtLinkUpdate) {
            expectEmit(address(registry));
            emit PtForUserUpdated(caller, ptAddress, _expectedLinkedMarketForPt);
        }

        // Register the market
        vm.prank(caller);
        registry.updateMarketsForCaller({_updateMarketInputs: updateMarketInputs, _skipValidation: _skipValidation});

        // Assert storage
        {
            address linkedMarketForPt = registry.getPtOracleMarketForUser({_user: caller, _ptAddress: ptAddress});
            uint32 marketDuration =
                registry.getMarketOracleDurationForUser({_user: caller, _marketAddress: _marketAddress});
            assertEq(linkedMarketForPt, _expectedLinkedMarketForPt, "Incorrect linked market for PT");
            assertEq(marketDuration, _duration, "Incorrect duration for market");
        }

        // Combined getter: getPtOracleMarketAndDurationForUser
        {
            (address combinedLinkedMarketForPt, uint32 combinedMarketDurationForPt) =
                registry.getPtOracleMarketAndDurationForUser({_user: caller, _ptAddress: ptAddress});
            assertEq(
                combinedLinkedMarketForPt, _expectedLinkedMarketForPt, "Incorrect combined getter: linked market for PT"
            );

            // Duration should be that of the linked market
            assertEq(
                combinedMarketDurationForPt,
                registry.getMarketOracleDurationForUser({_user: caller, _marketAddress: _expectedLinkedMarketForPt}),
                "Incorrect combined getter: incorrect duration"
            );
        }
    }
}
