// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IChainlinkPriceFeedMixin as IChainlinkPriceFeedMixinProd} from
    "contracts/release/infrastructure/price-feeds/primitives/IChainlinkPriceFeedMixin.sol";

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {IERC20} from "tests/interfaces/external/IERC20.sol";
import {ILidoSteth} from "tests/interfaces/external/ILidoSteth.sol";

import {IFundDeployer} from "tests/interfaces/internal/IFundDeployer.sol";
import {IValueInterpreter} from "tests/interfaces/internal/IValueInterpreter.sol";
import {IWstethPriceFeed} from "tests/interfaces/internal/IWstethPriceFeed.sol";

abstract contract WstethPriceFeedTestBase is IntegrationTest {
    IWstethPriceFeed internal priceFeed;

    EnzymeVersion internal version;

    function __initialize(EnzymeVersion _version) internal {
        version = _version;
        setUpMainnetEnvironment();
        priceFeed = __deployPriceFeed();
    }

    function __reinitialize(uint256 _forkBlock) private {
        setUpMainnetEnvironment(_forkBlock);
        priceFeed = __deployPriceFeed();
    }

    // DEPLOYMENT HELPERS

    function __deployPriceFeed() private returns (IWstethPriceFeed priceFeed_) {
        address addr = deployCode("WstethPriceFeed.sol", abi.encode(ETHEREUM_WSTETH, ETHEREUM_STETH));
        return IWstethPriceFeed(addr);
    }

    // MISC HELPERS

    function __addDerivativeAndUnderlying() private {
        addPrimitive({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHEREUM_STETH,
            _skipIfRegistered: false,
            _aggregatorAddress: ETHEREUM_STETH_ETH_AGGREGATOR,
            _rateAsset: IChainlinkPriceFeedMixinProd.RateAsset.ETH
        });
        addDerivative({
            _valueInterpreter: IValueInterpreter(getValueInterpreterAddressForVersion(version)),
            _tokenAddress: ETHEREUM_WSTETH,
            _skipIfRegistered: false,
            _priceFeedAddress: address(priceFeed)
        });
    }

    // TESTS

    function test_calcUnderlyingValuesForSpecificBlock_success() public {
        __reinitialize(ETHEREUM_BLOCK_TIME_SENSITIVE); // roll the fork block, and re-deploy

        __addDerivativeAndUnderlying();

        // EETH/USD price Sep 9th 2024 https://www.coingecko.com/en/coins/ether-fi-staked-eth/historical_data
        assertValueInUSDForVersion({
            _version: version,
            _asset: ETHEREUM_WSTETH,
            _amount: assetUnit(IERC20(ETHEREUM_WSTETH)),
            _expected: 2722400155739865283903 // 2722.400155739865283704 USD
        });
    }

    function test_calcUnderlyingValuesStETHInvariant_success() public {
        __addDerivativeAndUnderlying();

        uint256 value = IValueInterpreter(getValueInterpreterAddressForVersion(version)).calcCanonicalAssetValue({
            _baseAsset: ETHEREUM_WSTETH,
            _amount: assetUnit(IERC20(ETHEREUM_WSTETH)),
            _quoteAsset: ETHEREUM_STETH
        });

        uint256 wstETHCreationTimestamp = 1613752640;
        uint256 timePassed = block.timestamp - wstETHCreationTimestamp;
        uint256 maxDeviationPer365DaysInBps = 6 * BPS_ONE_PERCENT;

        uint256 underlyingSingleUnit = assetUnit(IERC20(ETHEREUM_STETH));

        // 1 WSTETH value must be always greater than 1 stETH
        assertGt(value, underlyingSingleUnit, "Value too low");
        assertLe(
            value,
            underlyingSingleUnit
                + (underlyingSingleUnit * maxDeviationPer365DaysInBps * timePassed) / (365 days * BPS_ONE_HUNDRED_PERCENT),
            "Deviation too high"
        );
    }

    function test_isSupportedAsset_success() public {
        assertTrue(priceFeed.isSupportedAsset({_asset: ETHEREUM_WSTETH}), "Unsupported token");
    }
}

contract WstethPriceFeedTestEthereum is WstethPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.Current);
    }
}

contract WstethPriceFeedTestEthereumV4 is WstethPriceFeedTestBase {
    function setUp() public override {
        __initialize(EnzymeVersion.V4);
    }
}
