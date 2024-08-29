// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {IERC20} from "tests/interfaces/external/IERC20.sol";

import {IStaderSDPriceFeed} from "tests/interfaces/internal/IStaderSDPriceFeed.sol";
import {IValueInterpreter} from "tests/interfaces/internal/IValueInterpreter.sol";

address constant STADER_ORACLE_ADDRESS = 0xF64bAe65f6f2a5277571143A24FaaFDFC0C2a737;
address constant SD_TOKEN_ADDRESS = 0x30D20208d987713f46DFD34EF128Bb16C404D10f;
uint256 constant FORK_BLOCK = 20139200; // June 21st 2024

abstract contract StaderSDPriceFeedTestBase is IntegrationTest {
    IStaderSDPriceFeed internal priceFeed;

    EnzymeVersion internal version;

    function __initialize(EnzymeVersion _version) internal {
        setUpMainnetEnvironment(FORK_BLOCK);
        version = _version;
        priceFeed = __deployPriceFeed();
    }

    // DEPLOYMENT HELPERS

    function __deployPriceFeed() private returns (IStaderSDPriceFeed) {
        address addr = deployCode(
            "StaderSDPriceFeed.sol", abi.encode(SD_TOKEN_ADDRESS, STADER_ORACLE_ADDRESS, address(wrappedNativeToken))
        );
        return IStaderSDPriceFeed(addr);
    }

    // MISC HELPERS

    function __addDerivative() private {
        addDerivative({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: SD_TOKEN_ADDRESS,
            _skipIfRegistered: false,
            _priceFeedAddress: address(priceFeed)
        });
    }

    // TESTS

    function test_calcUnderlyingValuesForSpecificBlock_success() public {
        __addDerivative();

        // SD/USD price on June 21st 2024. https://www.coingecko.com/en/coins/stader/historical_data
        assertValueInUSDForVersion({
            _version: version,
            _asset: SD_TOKEN_ADDRESS,
            _amount: assetUnit(IERC20(SD_TOKEN_ADDRESS)),
            _expected: 679518669667906813 // 0.679518669667906813 USD
        });
    }

    function test_isSupportedAsset_success() public {
        assertTrue(priceFeed.isSupportedAsset({_asset: SD_TOKEN_ADDRESS}), "Unsupported asset");
    }

    function test_isSupportedAsset_failWithUnsupportedAsset() public {
        assertFalse(priceFeed.isSupportedAsset({_asset: makeAddr("RandomToken")}), "Incorrectly supported asset");
    }
}

contract StaderSDPriceFeedTestEthereum is StaderSDPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.Current);
    }
}

contract StaderSDPriceFeedTestEthereumV4 is StaderSDPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.V4);
    }
}
