// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IIntegrationManager as IIntegrationManagerProd} from
    "contracts/release/extensions/integration-manager/IIntegrationManager.sol";

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {ICurveAddressProvider} from "tests/interfaces/external/ICurveAddressProvider.sol";
import {ICurveSwapRouter} from "tests/interfaces/external/ICurveSwapRouter.sol";
import {IERC20} from "tests/interfaces/external/IERC20.sol";

import {ICurveExchangeAdapter} from "tests/interfaces/internal/ICurveExchangeAdapter.sol";
import {IIntegrationAdapter} from "tests/interfaces/internal/IIntegrationAdapter.sol";

import {CurveUtils} from "./CurveUtils.sol";

abstract contract CurveExchangeAdapterTestBase is IntegrationTest, CurveUtils {
    IIntegrationAdapter internal adapter;
    ICurveSwapRouter internal curveSwapRouter;

    address internal fundOwner;
    address internal vaultProxyAddress;
    address internal comptrollerProxyAddress;

    address rawOutgoingAssetAddress;
    address rawIncomingAssetAddress;

    IERC20 outgoingAsset;
    IERC20 incomingAsset;

    EnzymeVersion internal version;

    function __initialize(
        EnzymeVersion _version,
        address _outgoingAssetAddress,
        address _incomingAssetAddress,
        uint256 _chainId
    ) internal {
        setUpNetworkEnvironment({_chainId: _chainId});

        version = _version;

        rawOutgoingAssetAddress = _outgoingAssetAddress;
        rawIncomingAssetAddress = _incomingAssetAddress;

        outgoingAsset = __parseNativeAsset(_outgoingAssetAddress);
        incomingAsset = __parseNativeAsset(_incomingAssetAddress);

        adapter = __deployAdapter();

        // Create fund
        (comptrollerProxyAddress, vaultProxyAddress, fundOwner) = createTradingFundForVersion(version);

        // Add the outgoingAsset and incomingAsset to the asset universe
        addPrimitiveWithTestAggregator({
            _valueInterpreter: core.release.valueInterpreter,
            _tokenAddress: address(outgoingAsset),
            _skipIfRegistered: true
        });
        addPrimitiveWithTestAggregator({
            _valueInterpreter: core.release.valueInterpreter,
            _tokenAddress: address(incomingAsset),
            _skipIfRegistered: true
        });

        // Seed the vault with the outgoingAsset
        increaseTokenBalance({_token: outgoingAsset, _to: vaultProxyAddress, _amount: assetUnit(outgoingAsset) * 3});

        // ID 2 is the Curve Swap Router.
        curveSwapRouter = ICurveSwapRouter(ICurveAddressProvider(ADDRESS_PROVIDER_ADDRESS).get_address(2));
    }

    // DEPLOYMENT HELPERS

    // Deploy the adapter
    function __deployAdapter() private returns (IIntegrationAdapter adapter_) {
        bytes memory args = abi.encode(
            getIntegrationManagerAddressForVersion(version), ADDRESS_PROVIDER_ADDRESS, address(wrappedNativeToken)
        );
        address addr = deployCode("CurveExchangeAdapter.sol", args);
        return IIntegrationAdapter(addr);
    }

    // MISC HELPERS

    function __parseNativeAsset(address _assetAddress) private view returns (IERC20 parsedAsset_) {
        return _assetAddress == NATIVE_ASSET_ADDRESS ? wrappedNativeToken : IERC20(_assetAddress);
    }

    // ACTION HELPERS

    function __takeOrder(
        address _pool,
        address _outgoingAsset,
        uint256 _outgoingAssetAmount,
        address _incomingAsset,
        uint256 _minIncomingAssetAmount
    ) internal {
        bytes memory actionArgs =
            abi.encode(_pool, _outgoingAsset, _outgoingAssetAmount, _incomingAsset, _minIncomingAssetAmount);

        vm.prank(fundOwner);
        callOnIntegrationForVersion({
            _version: version,
            _comptrollerProxyAddress: comptrollerProxyAddress,
            _adapterAddress: address(adapter),
            _selector: ICurveExchangeAdapter.takeOrder.selector,
            _actionArgs: actionArgs
        });
    }

    // TESTS

    function test_takeOrder_success() public {
        uint256 outgoingAmount = outgoingAsset.balanceOf(vaultProxyAddress) / 7;
        (address bestPoolAddress, uint256 expectedIncomingAmount) = curveSwapRouter.get_best_rate({
            _outgoingAssetAddress: rawOutgoingAssetAddress,
            _incomingAssetAddress: rawIncomingAssetAddress,
            _outgoingAssetAmount: outgoingAmount
        });

        // Allow for 10bps slippage
        uint256 minIncomingAmount = expectedIncomingAmount - (expectedIncomingAmount / 1000);

        uint256 preTakeOrderOutgoingAssetBalance = outgoingAsset.balanceOf(vaultProxyAddress);
        uint256 preTakeOrderIncomingAssetBalance = incomingAsset.balanceOf(vaultProxyAddress);

        vm.recordLogs();

        __takeOrder({
            _pool: bestPoolAddress,
            _outgoingAsset: address(outgoingAsset),
            _outgoingAssetAmount: outgoingAmount,
            _incomingAsset: address(incomingAsset),
            _minIncomingAssetAmount: minIncomingAmount
        });

        assertAdapterAssetsForAction({
            _logs: vm.getRecordedLogs(),
            _spendAssetsHandleTypeUint8: uint8(IIntegrationManagerProd.SpendAssetsHandleType.Transfer),
            _spendAssets: toArray(address(outgoingAsset)),
            _maxSpendAssetAmounts: toArray(outgoingAmount),
            _incomingAssets: toArray(address(incomingAsset)),
            _minIncomingAssetAmounts: toArray(minIncomingAmount)
        });

        uint256 postTakeOrderOutgoingAssetBalance = outgoingAsset.balanceOf(vaultProxyAddress);
        uint256 postTakeOrderIncomingAssetBalance = incomingAsset.balanceOf(vaultProxyAddress);

        assertApproxEqAbs(
            preTakeOrderOutgoingAssetBalance - postTakeOrderOutgoingAssetBalance,
            outgoingAmount,
            1,
            "Incorrect outgoing asset balance delta"
        );
        assertApproxEqRel(
            postTakeOrderIncomingAssetBalance - preTakeOrderIncomingAssetBalance,
            expectedIncomingAmount,
            WEI_ONE_PERCENT / 100,
            "Incorrect incoming asset balance delta"
        );
    }
}

contract EthereumCurveExchangeAdapterERC20Test is CurveExchangeAdapterTestBase {
    function setUp() public override {
        __initialize({
            _version: EnzymeVersion.Current,
            _outgoingAssetAddress: ETHEREUM_DAI,
            _incomingAssetAddress: ETHEREUM_USDC,
            _chainId: ETHEREUM_CHAIN_ID
        });
    }
}

contract EthereumCurveExchangeAdapterERC20TestV4 is CurveExchangeAdapterTestBase {
    function setUp() public override {
        __initialize({
            _version: EnzymeVersion.V4,
            _outgoingAssetAddress: ETHEREUM_DAI,
            _incomingAssetAddress: ETHEREUM_USDC,
            _chainId: ETHEREUM_CHAIN_ID
        });
    }
}

contract EthereumCurveExchangeAdapterOutgoingNativeAssetTest is CurveExchangeAdapterTestBase {
    function setUp() public override {
        __initialize({
            _version: EnzymeVersion.Current,
            _outgoingAssetAddress: NATIVE_ASSET_ADDRESS,
            _incomingAssetAddress: ETHEREUM_STETH,
            _chainId: ETHEREUM_CHAIN_ID
        });
    }
}

contract EthereumCurveExchangeAdapterOutgoingNativeAssetTestV4 is CurveExchangeAdapterTestBase {
    function setUp() public override {
        __initialize({
            _version: EnzymeVersion.V4,
            _outgoingAssetAddress: NATIVE_ASSET_ADDRESS,
            _incomingAssetAddress: ETHEREUM_STETH,
            _chainId: ETHEREUM_CHAIN_ID
        });
    }
}

contract EthereumCurveExchangeAdapterIncomingNativeAssetTest is CurveExchangeAdapterTestBase {
    function setUp() public override {
        __initialize({
            _version: EnzymeVersion.Current,
            _outgoingAssetAddress: ETHEREUM_STETH,
            _incomingAssetAddress: NATIVE_ASSET_ADDRESS,
            _chainId: ETHEREUM_CHAIN_ID
        });
    }
}

contract EthereumCurveExchangeAdapterIncomingNativeAssetTestV4 is CurveExchangeAdapterTestBase {
    function setUp() public override {
        __initialize({
            _version: EnzymeVersion.V4,
            _outgoingAssetAddress: ETHEREUM_STETH,
            _incomingAssetAddress: NATIVE_ASSET_ADDRESS,
            _chainId: ETHEREUM_CHAIN_ID
        });
    }
}

// The Curve Swap Router contract at `0x2a426b3Bb4fa87488387545f15D01d81352732F9` seems broken, leading to invalid get_best_rate queries.
// Tests can be uncommented once contract is fixed/replaced.
// contract PolygonCurveExchangeAdapterERC20Test is CurveExchangeAdapterTestBase {
//     function setUp() public override {
//         __initialize({
//             _version: EnzymeVersion.Current,
//             _outgoingAssetAddress: POLYGON_USDC,
//             _incomingAssetAddress: POLYGON_USDT,
//             _chainId: POLYGON_CHAIN_ID
//         });
//     }
// }

// contract PolygonCurveExchangeAdapterERC20TestV4 is CurveExchangeAdapterTestBase {
//     function setUp() public override {
//         __initialize({
//             _version: EnzymeVersion.V4,
//             _outgoingAssetAddress: POLYGON_USDC,
//             _incomingAssetAddress: POLYGON_USDT,
//             _chainId: POLYGON_CHAIN_ID
//         });
//     }
// }
