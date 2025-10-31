// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IAsync31ThirdPosition as IAsync31ThirdPositionProd} from
"contracts/release/extensions/external-position-manager/external-positions/async31Third/IAsync31ThirdPosition.sol";
import {IUintListRegistry as IUintListRegistryProd} from "contracts/persistent/uint-list-registry/IUintListRegistry.sol";

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

import {IAsync31Third} from "tests/interfaces/external/IAsync31Third.sol";
import {IAliceV2OrderManager} from "tests/interfaces/external/IAliceV2OrderManager.sol";
import {IAliceWhitelistManager} from "tests/interfaces/external/IAliceWhitelistManager.sol";
import {IERC20} from "tests/interfaces/external/IERC20.sol";

import {IExternalPositionManager} from "tests/interfaces/internal/IExternalPositionManager.sol";
import {IAsync31ThirdPositionLib} from "tests/interfaces/internal/IAsync31ThirdPositionLib.sol";
import {IAsync31ThirdPositionParser} from "tests/interfaces/internal/IAsync31ThirdPositionParser.sol";

import {console2} from "forge-std/console2.sol";

// POLYGON MAINNET CONSTANTS
address constant POLYGON_ASYNC31THIRD = 0x8d847F07c00063Aa61474ac75197001A4046722E;
address constant POLYGON_ALICE_ORDER_MANAGER = 0xB04a463219197046B6C581209f73077683520EB7;
address constant POLYGON_ALICE_WHITELIST = 0x714B492E367Db1a72C4864BA05baC13AB8A4Cbbc;
address constant POLYGON_WETH_ADDRESS = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
address constant POLYGON_USDC_ADDRESS = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

address constant NATIVE_ASSET_ADDRESS = address(0);

abstract contract Async31ThirdTestBase is IntegrationTest {
    event OrderIdAdded(uint256 indexed orderId, IAsync31ThirdPositionLib.OrderDetails orderDetails);

    event OrderIdRemoved(uint256 indexed orderId);

    struct BuildOrderDetails {
        uint256 orderId;
        IERC20 rawOutgoingAsset;
        IERC20 rawIncomingAsset;
        IERC20 outgoingAsset;
        IERC20 incomingAsset;
        uint256 orderQuantity;
        uint256 limitAmountToGet;
    }

    struct BuildAndPlaceOrderOutput {
        uint256 orderId;
        IERC20 outgoingAsset;
        IERC20 incomingAsset;
        uint256 orderQuantity;
        uint256 timestamp;
        uint256 limitAmountToGet;
    }

    uint256 internal async31ThirdTypeId;
    IAsync31ThirdPositionLib internal async31ThirdExternalPosition;
    IERC20 internal sellToken;
    IERC20 internal buyToken;

    IAsync31Third internal async31Third;
    address internal async31ThirdOwner;

    IAliceV2OrderManager internal aliceOrderManager;
    address internal aliceOwner;
    address internal liquidityPoolContract;

    address internal comptrollerProxyAddress;
    address internal fundOwner;
    address internal vaultProxyAddress;
    IExternalPositionManager internal externalPositionManager;

    EnzymeVersion internal version;

    function __initialize(
        EnzymeVersion _version,
        address _async31ThirdAddress,
        address _aliceOrderManager,
        address _aliceWhitelist,
        address _sellTokenAddress,
        address _buyTokenAddress,
        uint256 _chainId
    ) internal {
        version = _version;


        setUpNetworkEnvironment({_chainId: _chainId});

        externalPositionManager = IExternalPositionManager(getExternalPositionManagerAddressForVersion(version));
        async31ThirdTypeId = deployAsync31Third({
            _async31ThirdAddress: _async31ThirdAddress,
            _wrappedNativeAssetAddress: address(wrappedNativeToken)
        });

        async31Third = IAsync31Third(_async31ThirdAddress);
        async31ThirdOwner = async31Third.owner();

        aliceOrderManager = IAliceV2OrderManager(_aliceOrderManager);
        aliceOwner = aliceOrderManager.aliceKey();
        liquidityPoolContract = aliceOrderManager.liquidityPoolContract();

        (comptrollerProxyAddress, vaultProxyAddress, fundOwner) = createTradingFundForVersion(version);

        vm.prank(fundOwner);
        async31ThirdExternalPosition = IAsync31ThirdPositionLib(
            createExternalPositionForVersion({
                _version: version,
                _comptrollerProxyAddress: comptrollerProxyAddress,
                _typeId: async31ThirdTypeId,
                _initializationData: ""
            })
        );

        // Add the external position to Alice's whitelisted users
        IAliceWhitelistManager aliceWhitelistManager = IAliceWhitelistManager(_aliceWhitelist);
        vm.startPrank(aliceWhitelistManager.owner());
//        aliceWhitelistManager.addAddress({_userAddress: address(async31Third)});
        aliceWhitelistManager.addAddress({_userAddress: address(async31ThirdExternalPosition)});
        vm.stopPrank();

        sellToken = IERC20(_sellTokenAddress);
        buyToken = IERC20(_buyTokenAddress);

        // Increase the baseToken and quoteToken balances. Seed with weth if native asset is used.
        IERC20 parsedBaseToken = __parseAliceAsset({_rawAsset: sellToken});
        IERC20 parsedQuoteToken = __parseAliceAsset({_rawAsset: buyToken});

        // Add the base and quote tokens to the asset universe
        addPrimitiveWithTestAggregator({
            _valueInterpreter: core.release.valueInterpreter,
            _tokenAddress: address(parsedBaseToken),
            _skipIfRegistered: true
        });
        addPrimitiveWithTestAggregator({
            _valueInterpreter: core.release.valueInterpreter,
            _tokenAddress: address(parsedQuoteToken),
            _skipIfRegistered: true
        });
        increaseTokenBalance({_token: parsedBaseToken, _to: vaultProxyAddress, _amount: assetUnit(parsedBaseToken) * 7});
        increaseTokenBalance({
            _token: parsedQuoteToken,
            _to: vaultProxyAddress,
            _amount: assetUnit(parsedQuoteToken) * 11
        });
    }

    // DEPLOYMENT HELPERS

    function deployAsync31Third(address _async31ThirdAddress, address _wrappedNativeAssetAddress)
        public
        returns (uint256 typeId_)
    {
        IAsync31ThirdPositionLib async31ThirdPositionLib = deployAsync31ThirdPositionParserPositionLib({
            _async31ThirdAddress: _async31ThirdAddress,
            _wrappedNativeAssetAddress: _wrappedNativeAssetAddress
        });
        IAsync31ThirdPositionParser async31ThirdPositionParser = deployAsync31ThirdPositionParserPositionParser({
            _async31ThirdAddress: _async31ThirdAddress,
            _wrappedNativeAssetAddress: _wrappedNativeAssetAddress
        });

        typeId_ = registerExternalPositionTypeForVersion({
            _version: version,
            _label: "ASYNC31THIRD",
            _lib: address(async31ThirdPositionLib),
            _parser: address(async31ThirdPositionParser)
        });

        return (typeId_);
    }

    function deployAsync31ThirdPositionParserPositionLib(address _async31ThirdAddress, address _wrappedNativeAssetAddress)
        public
        returns (IAsync31ThirdPositionLib)
    {
        bytes memory args = abi.encode(_async31ThirdAddress, _wrappedNativeAssetAddress);
        address addr = deployCode("Async31ThirdPositionLib.sol", args);
        return IAsync31ThirdPositionLib(addr);
    }

    function deployAsync31ThirdPositionParserPositionParser(address _async31ThirdAddress, address _wrappedNativeAssetAddress)
        public
        returns (IAsync31ThirdPositionParser)
    {
        bytes memory args = abi.encode(_async31ThirdAddress, _wrappedNativeAssetAddress);
        address addr = deployCode("Async31ThirdPositionParser.sol", args);
        return IAsync31ThirdPositionParser(addr);
    }

    // ACTION HELPERS

    function __placeOrder(IAsync31ThirdPositionProd.PlaceOrderActionArgs memory _args) private {
        vm.prank(fundOwner);

        callOnExternalPositionForVersion({
            _version: version,
            _comptrollerProxyAddress: comptrollerProxyAddress,
            _externalPositionAddress: address(async31ThirdExternalPosition),
            _actionId: uint256(IAsync31ThirdPositionProd.Actions.PlaceOrder),
            _actionArgs: abi.encode(_args)
        });
    }

    function __placeOrders(IAsync31ThirdPositionProd.PlaceOrdersActionArgs memory _args) private {
        vm.prank(fundOwner);

        console2.logBytes(abi.encode(_args));

        callOnExternalPositionForVersion({
            _version: version,
            _comptrollerProxyAddress: comptrollerProxyAddress,
            _externalPositionAddress: address(async31ThirdExternalPosition),
            _actionId: uint256(IAsync31ThirdPositionProd.Actions.PlaceOrders),
            _actionArgs: abi.encode(_args)
        });
    }

    function __refundOrder(IAsync31ThirdPositionProd.RefundOrderActionArgs memory _args) private {
        vm.prank(fundOwner);

        callOnExternalPositionForVersion({
            _version: version,
            _comptrollerProxyAddress: comptrollerProxyAddress,
            _externalPositionAddress: address(async31ThirdExternalPosition),
            _actionId: uint256(IAsync31ThirdPositionProd.Actions.RefundOrder),
            _actionArgs: abi.encode(_args)
        });
    }

    function __refundOrders(IAsync31ThirdPositionProd.RefundOrdersActionArgs memory _args) private {
        vm.prank(fundOwner);

        callOnExternalPositionForVersion({
            _version: version,
            _comptrollerProxyAddress: comptrollerProxyAddress,
            _externalPositionAddress: address(async31ThirdExternalPosition),
            _actionId: uint256(IAsync31ThirdPositionProd.Actions.RefundOrders),
            _actionArgs: abi.encode(_args)
        });
    }

    function __sweep(IAsync31ThirdPositionProd.SweepActionArgs memory _args) private {
        vm.prank(fundOwner);

        callOnExternalPositionForVersion({
            _version: version,
            _comptrollerProxyAddress: comptrollerProxyAddress,
            _externalPositionAddress: address(async31ThirdExternalPosition),
            _actionId: uint256(IAsync31ThirdPositionProd.Actions.Sweep),
            _actionArgs: abi.encode(_args)
        });
    }

    function __buildOrder()
        private
        view
        returns (
            IAsync31ThirdPositionProd.PlaceOrderActionArgs memory placeOrderArgs_,
            BuildOrderDetails memory buildOrderDetails_
        )
    {
        IERC20 outgoingAsset = __parseAliceAsset({_rawAsset: sellToken});
        IERC20 incomingAsset = __parseAliceAsset({_rawAsset: buyToken});

        buildOrderDetails_ = BuildOrderDetails({
            orderId: async31Third.nextOrderId(),
            rawOutgoingAsset: sellToken,
            rawIncomingAsset: buyToken,
            outgoingAsset: outgoingAsset,
            incomingAsset: incomingAsset,
            orderQuantity: outgoingAsset.balanceOf(vaultProxyAddress) / 3,
            limitAmountToGet: assetUnit({_asset: incomingAsset}) * 7
        });

        placeOrderArgs_ = IAsync31ThirdPositionProd.PlaceOrderActionArgs(IAsync31ThirdPositionProd.OrderRequest({
            sellToken: address(buildOrderDetails_.outgoingAsset),
            buyToken: address(buildOrderDetails_.incomingAsset),
            amountToSell: buildOrderDetails_.orderQuantity,
            limitAmountToGet: buildOrderDetails_.limitAmountToGet
        }));
    }

    function __buildOrders(uint256 orderCount)
    private
    view
    returns (
        IAsync31ThirdPositionProd.PlaceOrdersActionArgs memory placeOrderArgs_,
        BuildOrderDetails[] memory buildOrdersDetails_
    )
    {
        buildOrdersDetails_ = new BuildOrderDetails[](orderCount);
        IAsync31ThirdPositionProd.OrderRequest[] memory orderRequests = new IAsync31ThirdPositionProd.OrderRequest[](orderCount);

        uint256 orderId = async31Third.nextOrderId();
        IERC20 outgoingAsset = __parseAliceAsset({_rawAsset: sellToken});
        IERC20 incomingAsset = __parseAliceAsset({_rawAsset: buyToken});

        for (uint256 i; i < orderCount; i++) {
            buildOrdersDetails_[i] = BuildOrderDetails({
                orderId: orderId + i,
                rawOutgoingAsset: sellToken,
                rawIncomingAsset: buyToken,
                outgoingAsset: outgoingAsset,
                incomingAsset: incomingAsset,
                orderQuantity: outgoingAsset.balanceOf(vaultProxyAddress) / (orderCount + 1),
                limitAmountToGet: assetUnit({_asset: incomingAsset}) * 3 - (i * orderCount)
            });
            orderRequests[i] = IAsync31ThirdPositionProd.OrderRequest({
                sellToken: address(buildOrdersDetails_[i].outgoingAsset),
                buyToken: address(buildOrdersDetails_[i].incomingAsset),
                amountToSell: buildOrdersDetails_[i].orderQuantity,
                limitAmountToGet: buildOrdersDetails_[i].limitAmountToGet
            });
        }

        placeOrderArgs_ = IAsync31ThirdPositionProd.PlaceOrdersActionArgs(orderRequests);
    }

    function __buildAndPlaceOrder() private returns (BuildAndPlaceOrderOutput memory output_) {
        (
            IAsync31ThirdPositionProd.PlaceOrderActionArgs memory placeOrderActionArgs,
            BuildOrderDetails memory buildOrderDetails_
        ) = __buildOrder();

        uint256 timestamp = block.timestamp;

        __placeOrder(placeOrderActionArgs);

        return (
            BuildAndPlaceOrderOutput({
                orderId: buildOrderDetails_.orderId,
                outgoingAsset: buildOrderDetails_.outgoingAsset,
                incomingAsset: buildOrderDetails_.incomingAsset,
                orderQuantity: buildOrderDetails_.orderQuantity,
                timestamp: timestamp,
                limitAmountToGet: buildOrderDetails_.limitAmountToGet
            })
        );
    }

    function __buildAndPlaceOrders(uint256 orderCount) private returns (BuildAndPlaceOrderOutput[] memory outputs_) {
        (
            IAsync31ThirdPositionProd.PlaceOrdersActionArgs memory placeOrdersActionArgs,
            BuildOrderDetails[] memory buildOrdersDetails_
        ) = __buildOrders(orderCount);

        uint256 timestamp = block.timestamp;

        __placeOrders(placeOrdersActionArgs);

        outputs_ = new BuildAndPlaceOrderOutput[](orderCount);
        for (uint256 i; i < orderCount; i++) {
            outputs_[i] = BuildAndPlaceOrderOutput({
                orderId: buildOrdersDetails_[i].orderId,
                outgoingAsset: buildOrdersDetails_[i].outgoingAsset,
                incomingAsset: buildOrdersDetails_[i].incomingAsset,
                orderQuantity: buildOrdersDetails_[i].orderQuantity,
                timestamp: timestamp,
                limitAmountToGet: buildOrdersDetails_[i].limitAmountToGet
            });
        }
    }

    function __cancelOrder(uint256 _orderId, uint256 _limitAmountToGet, uint256 _timestamp)
        private
    {
        IAsync31ThirdPositionLib.OrderDetails memory orderDetails = async31ThirdExternalPosition.getOrderDetails({_orderId: _orderId});
        IAsync31Third.Order memory order = async31Third.orders(_orderId);

        vm.prank(aliceOwner);

        aliceOrderManager.cancelOrderWithReference({
            _orderId: order.aliceOrderId,
            _user: address(async31Third),
            _tokenToSell: orderDetails.outgoingAssetAddress,
            _tokenToBuy: orderDetails.incomingAssetAddress,
            _quantityToSell: orderDetails.outgoingAmount,
            _limitAmountToGet: _limitAmountToGet,
            _timestamp: _timestamp,
            receiver: address(async31Third),
            refId: bytes32(_orderId)
        });
    }

    function __parseAliceAsset(IERC20 _rawAsset) private view returns (IERC20 parsedAsset_) {
        return address(_rawAsset) == NATIVE_ASSET_ADDRESS ? wrappedNativeToken : _rawAsset;
    }

    function __settleOrder(
        uint256 _orderId,
        uint256 _limitAmountToGet,
        uint256 _timestamp,
        uint256 _settlementAmount
    ) private {
        IAsync31ThirdPositionLib.OrderDetails memory orderDetails = async31ThirdExternalPosition.getOrderDetails({_orderId: _orderId});
        IAsync31Third.Order memory order = async31Third.orders(_orderId);

        // Seed the liquidity pool so that funds are available to trade
        IERC20 incomingAsset = __parseAliceAsset({_rawAsset: IERC20(orderDetails.incomingAssetAddress)});

        increaseTokenBalance({
            _token: incomingAsset,
            _to: liquidityPoolContract,
            _amount: assetUnit(incomingAsset) * 12345
        });

        bytes32 refId = bytes32(_orderId);

        vm.prank(aliceOwner);

        aliceOrderManager.settleOrderWithReference({
            _orderId: order.aliceOrderId,
            _user: address(async31Third),
            _tokenToSell: orderDetails.outgoingAssetAddress,
            _tokenToBuy: orderDetails.incomingAssetAddress,
            _quantityToSell: orderDetails.outgoingAmount,
            _limitAmountToGet: _limitAmountToGet,
            _timestamp: _timestamp,
            _quantityReceivedPreFee: _settlementAmount,
            receiver: address(async31Third),
            refId: refId
        });
    }

    // TESTS

    function test_placeOrder() public {
        (
            IAsync31ThirdPositionProd.PlaceOrderActionArgs memory placeOrderActionArgs,
            BuildOrderDetails memory buildOrderDetails_
        ) = __buildOrder();

        vm.recordLogs();

        expectEmit(address(async31ThirdExternalPosition));
        emit OrderIdAdded(
            buildOrderDetails_.orderId,
            IAsync31ThirdPositionLib.OrderDetails(
                address(buildOrderDetails_.outgoingAsset),
                address(buildOrderDetails_.incomingAsset),
                buildOrderDetails_.orderQuantity
            )
        );

        uint256 preOrderVaultOutgoingAssetBalance = buildOrderDetails_.outgoingAsset.balanceOf(vaultProxyAddress);

        __placeOrder({_args: placeOrderActionArgs});

        uint256 postOrderVaultOutgoingAssetBalance = buildOrderDetails_.outgoingAsset.balanceOf(vaultProxyAddress);

        assertExternalPositionAssetsToReceive({
            _logs: vm.getRecordedLogs(),
            _externalPositionManager: externalPositionManager,
            _assets: new address[](0)
        });

        // The orderId should have been added to storage
        assertEq(toArray(buildOrderDetails_.orderId), async31ThirdExternalPosition.getOrderIds(), "Incorrect orderIds");
        // The order details should have been added to storage
        IAsync31ThirdPositionLib.OrderDetails memory orderDetails = async31ThirdExternalPosition.getOrderDetails({_orderId: buildOrderDetails_.orderId});
        assertEq(orderDetails.outgoingAssetAddress, address(buildOrderDetails_.outgoingAsset), "Incorrect outgoingAssetAddress");
        assertEq(orderDetails.incomingAssetAddress, address(buildOrderDetails_.incomingAsset), "Incorrect incomingAssetAddress");
        assertEq(orderDetails.outgoingAmount, buildOrderDetails_.orderQuantity, "Incorrect outgoingAmount");

        // The vaultProxy should have been debited the quantityToSell
        assertEq(
            preOrderVaultOutgoingAssetBalance - postOrderVaultOutgoingAssetBalance,
            buildOrderDetails_.orderQuantity,
            "Incorrect vaultProxy balance"
        );

        // The EP should report the placedOrder in getManagedAssets
        (address[] memory managedAssets, uint256[] memory managedAssetAmounts) =
            async31ThirdExternalPosition.getManagedAssets();
        assertEq(managedAssets, toArray(address(buildOrderDetails_.outgoingAsset)), "Incorrect managedAssets");
        assertEq(managedAssetAmounts, toArray(buildOrderDetails_.orderQuantity), "Incorrect managedAssetAmounts");
    }

    function test_placeOrders1() public {
        uint256 orderCount = 3;

        (
            IAsync31ThirdPositionProd.PlaceOrdersActionArgs memory placeOrdersActionArgs,
            BuildOrderDetails[] memory buildOrdersDetails_
        ) = __buildOrders(orderCount);

        vm.recordLogs();

        for (uint256 i; i < orderCount; i++) {
            expectEmit(address(async31ThirdExternalPosition));
            emit OrderIdAdded(
                buildOrdersDetails_[i].orderId,
                IAsync31ThirdPositionLib.OrderDetails(
                    address(buildOrdersDetails_[i].outgoingAsset),
                    address(buildOrdersDetails_[i].incomingAsset),
                    buildOrdersDetails_[i].orderQuantity
                )
            );
        }

        // All orders use same assets
        uint256 preOrderVaultOutgoingAssetBalance = buildOrdersDetails_[0].outgoingAsset.balanceOf(vaultProxyAddress);

        __placeOrders({_args: placeOrdersActionArgs});

        uint256 postOrderVaultOutgoingAssetBalance = buildOrdersDetails_[0].outgoingAsset.balanceOf(vaultProxyAddress);

        assertExternalPositionAssetsToReceive({
            _logs: vm.getRecordedLogs(),
            _externalPositionManager: externalPositionManager,
            _assets: new address[](0)
        });

        // The orderId should have been added to storage
        assertEq(toArray(
            buildOrdersDetails_[0].orderId,
            buildOrdersDetails_[1].orderId,
            buildOrdersDetails_[2].orderId
        ), async31ThirdExternalPosition.getOrderIds(), "Incorrect orderIds");

        uint256 orderQuantity = 0;
        for (uint256 i; i < orderCount; i++) {
            // The order details should have been added to storage
            IAsync31ThirdPositionLib.OrderDetails memory orderDetails = async31ThirdExternalPosition.getOrderDetails({_orderId: buildOrdersDetails_[i].orderId});
            assertEq(orderDetails.outgoingAssetAddress, address(buildOrdersDetails_[i].outgoingAsset), "Incorrect outgoingAssetAddress");
            assertEq(orderDetails.incomingAssetAddress, address(buildOrdersDetails_[i].incomingAsset), "Incorrect incomingAssetAddress");
            assertEq(orderDetails.outgoingAmount, buildOrdersDetails_[i].orderQuantity, "Incorrect outgoingAmount");
            orderQuantity += buildOrdersDetails_[i].orderQuantity;
        }

        // The vaultProxy should have been debited the quantityToSell
        assertEq(
            preOrderVaultOutgoingAssetBalance - postOrderVaultOutgoingAssetBalance,
            orderQuantity,
            "Incorrect vaultProxy balance"
        );

        // The EP should report the placedOrder in getManagedAssets
        (address[] memory managedAssets, uint256[] memory managedAssetAmounts) =
                            async31ThirdExternalPosition.getManagedAssets();
        assertEq(managedAssets, toArray(address(buildOrdersDetails_[0].outgoingAsset)), "Incorrect managedAssets");
        assertEq(managedAssetAmounts, toArray(orderQuantity), "Incorrect managedAssetAmounts");
    }

    function test_refundOrder_success() public {
        BuildAndPlaceOrderOutput memory orderOutput = __buildAndPlaceOrder();

        uint256 preRefundVaultBalance = orderOutput.outgoingAsset.balanceOf(vaultProxyAddress);

        // Warp to the time where refunds are allowed
        skip(aliceOrderManager.refundTimeoutSeconds());

        vm.recordLogs();

        expectEmit(address(async31ThirdExternalPosition));
        emit OrderIdRemoved(orderOutput.orderId);

        __refundOrder(
            IAsync31ThirdPositionProd.RefundOrderActionArgs({
                orderId: orderOutput.orderId
            })
        );

        uint256 postRefundVaultBalance = orderOutput.outgoingAsset.balanceOf(vaultProxyAddress);

        assertExternalPositionAssetsToReceive({
            _logs: vm.getRecordedLogs(),
            _externalPositionManager: externalPositionManager,
            _assets: toArray(address(orderOutput.outgoingAsset))
        });

        // The order should have been removed from storage
        assertEq(0, async31ThirdExternalPosition.getOrderIds().length, "Incorrect orderIds length");
        assertEq(
            0,
            async31ThirdExternalPosition.getOrderDetails({_orderId: orderOutput.orderId}).outgoingAmount,
            "Incorrect orderDetails"
        );

        // The vaultProxy should have been credited the orderQuantity
        assertEq(postRefundVaultBalance - preRefundVaultBalance, orderOutput.orderQuantity, "Incorrect refund amount");
    }

    function test_refundOrders_success() public {
        uint256 orderCount = 3;
        BuildAndPlaceOrderOutput[] memory orderOutputs = __buildAndPlaceOrders(orderCount);

        // All orders use same assets
        uint256 preRefundVaultBalance = orderOutputs[0].outgoingAsset.balanceOf(vaultProxyAddress);

        // Warp to the time where refunds are allowed
        skip(aliceOrderManager.refundTimeoutSeconds());

        vm.recordLogs();

        uint256[] memory orderIds = new uint256[](orderCount);
        uint256 orderQuantity = 0;

        for (uint256 i; i < orderCount; i++) {
            expectEmit(address(async31ThirdExternalPosition));
            emit OrderIdRemoved(orderOutputs[i].orderId);
            orderIds[i] = orderOutputs[i].orderId;
            orderQuantity += orderOutputs[i].orderQuantity;
        }

        __refundOrders(
            IAsync31ThirdPositionProd.RefundOrdersActionArgs({
                orderIds: orderIds
            })
        );

        uint256 postRefundVaultBalance = orderOutputs[0].outgoingAsset.balanceOf(vaultProxyAddress);

        assertExternalPositionAssetsToReceive({
            _logs: vm.getRecordedLogs(),
            _externalPositionManager: externalPositionManager,
            _assets: toArray(address(orderOutputs[0].outgoingAsset))
        });

        // The order should have been removed from storage
        assertEq(0, async31ThirdExternalPosition.getOrderIds().length, "Incorrect orderIds length");
        assertEq(
            0,
            async31ThirdExternalPosition.getOrderDetails({_orderId: orderOutputs[0].orderId}).outgoingAmount,
            "Incorrect orderDetails"
        );

        // The vaultProxy should have been credited the orderQuantity
        assertEq(postRefundVaultBalance - preRefundVaultBalance, orderQuantity, "Incorrect refund amount");
    }

    function test_settleOrder_success() public {
        BuildAndPlaceOrderOutput memory orderOutput = __buildAndPlaceOrder();
        uint256 settlementAmount = orderOutput.limitAmountToGet * 3;

        uint256 preVaultBalance = orderOutput.incomingAsset.balanceOf(vaultProxyAddress);

        vm.recordLogs();
        expectEmit(address(async31ThirdExternalPosition));
        emit OrderIdRemoved(orderOutput.orderId);

        // Settle order should call notifySettle on EP which should directly return token to vault
        __settleOrder({
            _orderId: orderOutput.orderId,
            _limitAmountToGet: orderOutput.limitAmountToGet,
            _timestamp: orderOutput.timestamp,
            _settlementAmount: settlementAmount
        });

        uint256 postVaultBalance = orderOutput.incomingAsset.balanceOf(vaultProxyAddress);

        // The order should have been removed from storage
        assertEq(0, async31ThirdExternalPosition.getOrderIds().length, "Incorrect orderIds length");
        assertEq(
            0,
            async31ThirdExternalPosition.getOrderDetails({_orderId: orderOutput.orderId}).outgoingAmount,
            "Incorrect orderDetails"
        );

        uint256 aliceFeeRate = aliceOrderManager.feeRate(address(async31Third));
        uint256 async31ThirdFeeRate = async31Third.feeBPS();
        uint256 expectedAliceIncomingAmount = settlementAmount - settlementAmount * aliceFeeRate / BPS_ONE_HUNDRED_PERCENT;
        uint256 expectedIncomingAmount = expectedAliceIncomingAmount - expectedAliceIncomingAmount * async31ThirdFeeRate / BPS_ONE_HUNDRED_PERCENT;

        // The vaultProxy should have been credited the orderQuantity
        assertEq(postVaultBalance - preVaultBalance, expectedIncomingAmount, "Incorrect return amount");
    }

    function test_settleOrders_success() public {
        uint256 orderCount = 3;
        BuildAndPlaceOrderOutput[] memory orderOutputs = __buildAndPlaceOrders(3);

        // All orders use same assets
        uint256 preVaultBalance = orderOutputs[0].incomingAsset.balanceOf(vaultProxyAddress);
        uint256 settlementAmountSum = 0;

        for (uint256 i; i < orderCount; i++) {
            uint256 settlementAmount = orderOutputs[i].limitAmountToGet * 3;
            settlementAmountSum += settlementAmount;

            vm.recordLogs();
            expectEmit(address(async31ThirdExternalPosition));
            emit OrderIdRemoved(orderOutputs[i].orderId);

            // Settle order should call notifySettle on EP which should directly return token to vault
            __settleOrder({
                _orderId: orderOutputs[i].orderId,
                _limitAmountToGet: orderOutputs[i].limitAmountToGet,
                _timestamp: orderOutputs[i].timestamp,
                _settlementAmount: settlementAmount
            });
        }

        uint256 postVaultBalance = orderOutputs[0].incomingAsset.balanceOf(vaultProxyAddress);

        // The order should have been removed from storage
        assertEq(0, async31ThirdExternalPosition.getOrderIds().length, "Incorrect orderIds length");
        assertEq(
            0,
            async31ThirdExternalPosition.getOrderDetails({_orderId: orderOutputs[0].orderId}).outgoingAmount,
            "Incorrect orderDetails"
        );

        uint256 aliceFeeRate = aliceOrderManager.feeRate(address(async31Third));
        uint256 async31ThirdFeeRate = async31Third.feeBPS();
        uint256 expectedAliceIncomingAmount = settlementAmountSum - settlementAmountSum * aliceFeeRate / BPS_ONE_HUNDRED_PERCENT;
        uint256 expectedIncomingAmount = expectedAliceIncomingAmount - expectedAliceIncomingAmount * async31ThirdFeeRate / BPS_ONE_HUNDRED_PERCENT;

        // The vaultProxy should have been credited the orderQuantity
        assertApproxEqAbs(postVaultBalance - preVaultBalance, expectedIncomingAmount, 3, "Incorrect return amount");
    }

    function test_cancelOrder_success() public {
        BuildAndPlaceOrderOutput memory orderOutput = __buildAndPlaceOrder();

        uint256 preVaultBalance = orderOutput.outgoingAsset.balanceOf(vaultProxyAddress);

        vm.recordLogs();
        expectEmit(address(async31ThirdExternalPosition));
        emit OrderIdRemoved(orderOutput.orderId);

        // Cancel order should call notifyCancel on EP which should directly return token to vault
        __cancelOrder({
            _orderId: orderOutput.orderId,
            _limitAmountToGet: orderOutput.limitAmountToGet,
            _timestamp: orderOutput.timestamp
        });

        uint256 postVaultBalance = orderOutput.outgoingAsset.balanceOf(vaultProxyAddress);

        // The order should have been removed from storage
        assertEq(0, async31ThirdExternalPosition.getOrderIds().length, "Incorrect orderIds length");
        assertEq(
            0,
            async31ThirdExternalPosition.getOrderDetails({_orderId: orderOutput.orderId}).outgoingAmount,
            "Incorrect orderDetails"
        );

        // The vaultProxy should have been credited the orderQuantity
        assertEq(postVaultBalance - preVaultBalance, orderOutput.orderQuantity, "Incorrect return amount");
    }

    function test_sweep_success() public {
        BuildAndPlaceOrderOutput memory orderOutput = __buildAndPlaceOrder();

        // Cancel the order so that funds are available for sweeping
        __cancelOrder({
            _orderId: orderOutput.orderId,
            _limitAmountToGet: orderOutput.limitAmountToGet,
            _timestamp: orderOutput.timestamp
        });

        // The EP should report the reimbursed funds
        (address[] memory managedAssets, uint256[] memory managedAssetAmounts) =
            async31ThirdExternalPosition.getManagedAssets();
        assertEq(managedAssets, toArray(address(orderOutput.outgoingAsset)), "Incorrect managedAssets");
        assertEq(managedAssetAmounts, toArray(orderOutput.orderQuantity), "Incorrect managedAssetAmounts");

        uint256 preSweepVaultBalance = orderOutput.outgoingAsset.balanceOf(vaultProxyAddress);

        vm.recordLogs();

        expectEmit(address(async31ThirdExternalPosition));
        emit OrderIdRemoved(orderOutput.orderId);

        __sweep(IAsync31ThirdPositionProd.SweepActionArgs({orderIds: toArray(orderOutput.orderId)}));

        // The outgoing assets should be receivable (as the order was cancelled and the outgoing assets refunded)
        assertExternalPositionAssetsToReceive({
            _logs: vm.getRecordedLogs(),
            _externalPositionManager: externalPositionManager,
            _assets: toArray(address(orderOutput.outgoingAsset))
        });

        uint256 postSweepVaultBalance = orderOutput.outgoingAsset.balanceOf(vaultProxyAddress);

        // The order should have been removed from storage
        assertEq(0, async31ThirdExternalPosition.getOrderIds().length, "Incorrect orderIds length");
        assertEq(
            0,
            async31ThirdExternalPosition.getOrderDetails({_orderId: orderOutput.orderId}).outgoingAmount,
            "Incorrect orderDetails"
        );

        // The vaultProxy should have been credited the orderQuantity
        assertEq(postSweepVaultBalance - preSweepVaultBalance, orderOutput.orderQuantity, "Incorrect sweep amount");
    }

    function test_settledOrderValuation_success() public {
        BuildAndPlaceOrderOutput memory orderOutput = __buildAndPlaceOrder();

        uint256 settlementAmount = orderOutput.limitAmountToGet * 3;

        // Settle the order so that the proceeds are available for sweeping
        __settleOrder({
            _orderId: orderOutput.orderId,
            _limitAmountToGet: orderOutput.limitAmountToGet,
            _timestamp: orderOutput.timestamp,
            _settlementAmount: settlementAmount
        });

        uint256 preSweepIncomingAssetVaultBalance = orderOutput.incomingAsset.balanceOf(vaultProxyAddress);

        // Sweep the order
        __sweep(IAsync31ThirdPositionProd.SweepActionArgs({orderIds: toArray(orderOutput.orderId)}));
        uint256 postSweepIncomingAssetVaultBalance = orderOutput.incomingAsset.balanceOf(vaultProxyAddress);

        // The order should have been removed from storage
        assertEq(0, async31ThirdExternalPosition.getOrderIds().length, "Incorrect orderIds length");
        assertEq(
            0,
            async31ThirdExternalPosition.getOrderDetails({_orderId: orderOutput.orderId}).outgoingAmount,
            "Incorrect orderDetails"
        );

        uint256 aliceFeeRate = aliceOrderManager.feeRate(address(async31Third));
        uint256 async31ThirdFeeRate = async31Third.feeBPS();
        uint256 expectedAliceIncomingAmount = settlementAmount - settlementAmount * aliceFeeRate / BPS_ONE_HUNDRED_PERCENT;
        uint256 expectedIncomingAmount = expectedAliceIncomingAmount - expectedAliceIncomingAmount * async31ThirdFeeRate / BPS_ONE_HUNDRED_PERCENT;

        // The vaultProxy should have been credited the orderQuantity
        assertEq(
            postSweepIncomingAssetVaultBalance - preSweepIncomingAssetVaultBalance,
            expectedIncomingAmount,
            "Incorrect sweep amount"
        );
    }

//    function test_multiplePositionsValuation_success() public {
//        // Order #1 - Place a buy order
//        BuildAndPlaceOrderOutput memory firstOrderOutput = __buildAndPlaceOrder({_isBuyOrder: true});
//
//        // Order #2 - Place a sell order
//        BuildAndPlaceOrderOutput memory secondOrderOutput = __buildAndPlaceOrder({_isBuyOrder: false});
//
//        // Order #3 - Place an order with a different instrument
//        uint16 otherInstrumentId = instrumentId + 1;
//        IAliceOrderManager.Instrument memory otherInstrument =
//            aliceOrderManager.getInstrument({_instrumentId: otherInstrumentId, _mustBeActive: false});
//
//        uint256 thirdOrderId = aliceOrderManager.getMostRecentOrderId() + 1;
//        IERC20 thirdOutgoingAsset = __parseAliceAsset({_rawAsset: IERC20(otherInstrument.base)});
//        IERC20 thirdIncomingAsset = __parseAliceAsset({_rawAsset: IERC20(otherInstrument.quote)});
//
//        // Add the outgoing and incoming tokens to the asset universe
//        addPrimitiveWithTestAggregator({
//            _valueInterpreter: core.release.valueInterpreter,
//            _tokenAddress: address(thirdOutgoingAsset),
//            _skipIfRegistered: true
//        });
//        addPrimitiveWithTestAggregator({
//            _valueInterpreter: core.release.valueInterpreter,
//            _tokenAddress: address(thirdIncomingAsset),
//            _skipIfRegistered: true
//        });
//        increaseTokenBalance({
//            _token: thirdOutgoingAsset,
//            _to: vaultProxyAddress,
//            _amount: assetUnit(thirdOutgoingAsset) * 7
//        });
//        increaseTokenBalance({
//            _token: thirdIncomingAsset,
//            _to: vaultProxyAddress,
//            _amount: assetUnit(thirdOutgoingAsset) * 11
//        });
//
//        uint256 thirdOrderQuantity = thirdOutgoingAsset.balanceOf(vaultProxyAddress) / 3;
//        uint256 thirdOrderLimitAmountToGet = assetUnit({_asset: thirdIncomingAsset}) * 7;
//        uint256 thirdOrderTimestamp = block.timestamp;
//
//        __placeOrder({
//            _args: IAsync31ThirdPositionProd.PlaceOrderActionArgs({
//                instrumentId: otherInstrumentId,
//                isBuyOrder: false,
//                quantityToSell: thirdOrderQuantity,
//                limitAmountToGet: thirdOrderLimitAmountToGet
//            })
//        });
//
//        // Orders should be valued according to the value of the outgoing assets
//        {
//            {
//                (address[] memory pendingOrdersManagedAssets, uint256[] memory pendingOrdersManagedAssetAmounts) =
//                    async31ThirdExternalPosition.getManagedAssets();
//                assertEq(
//                    pendingOrdersManagedAssets,
//                    toArray(
//                        address(firstOrderOutput.outgoingAsset),
//                        address(secondOrderOutput.outgoingAsset),
//                        address(thirdOutgoingAsset)
//                    ),
//                    "Incorrect managedAssets"
//                );
//                assertEq(
//                    pendingOrdersManagedAssetAmounts,
//                    toArray(firstOrderOutput.orderQuantity, secondOrderOutput.orderQuantity, thirdOrderQuantity),
//                    "Incorrect managedAssetAmounts"
//                );
//            }
//        }
//
//        // Settle order #1, leave order #2 unchanged, and cancel order #3
//        uint256 firstOrderNetIncomingAmount;
//        {
//            uint256 firstOrderSettlementAmount = firstOrderOutput.limitAmountToGet * 3;
//            // Settle order #1
//            __settleOrder({
//                _orderId: firstOrderOutput.orderId,
//                _instrumentId: instrumentId,
//                _limitAmountToGet: firstOrderOutput.limitAmountToGet,
//                _timestamp: firstOrderOutput.timestamp,
//                _settlementAmount: firstOrderSettlementAmount
//            });
//
//            // Cancel order #3
//            __cancelOrder({
//                _orderId: thirdOrderId,
//                _instrumentId: otherInstrumentId,
//                _limitAmountToGet: thirdOrderLimitAmountToGet,
//                _timestamp: thirdOrderTimestamp
//            });
//
//            firstOrderNetIncomingAmount = firstOrderSettlementAmount
//                - firstOrderSettlementAmount * aliceOrderManager.feeRate() / BPS_ONE_HUNDRED_PERCENT;
//        }
//
//        // Orders should be properly valued
//        // Order #1 is now valued according to the settled amount in the incoming asset
//        // Order #2 is still valued according to the value of the outgoing asset (same as order #1 incomingAsset)
//        // Order #3 is now valued at the cancelled amount
//        {
//            (address[] memory settledOrdersManagedAssets, uint256[] memory settledOrdersManagedAssetAmounts) =
//                async31ThirdExternalPosition.getManagedAssets();
//            assertEq(
//                settledOrdersManagedAssets,
//                toArray(address(firstOrderOutput.incomingAsset), address(thirdOutgoingAsset)),
//                "Incorrect managedAssets"
//            );
//            assertEq(
//                settledOrdersManagedAssetAmounts,
//                toArray(firstOrderNetIncomingAmount + secondOrderOutput.orderQuantity, thirdOrderQuantity),
//                "Incorrect managedAssetAmounts"
//            );
//        }
//    }
}

contract Async31ThirdPolUsdcTestPolygon is Async31ThirdTestBase {
    function setUp() public override {
        __initialize({
            _version: EnzymeVersion.Current,
            _async31ThirdAddress: POLYGON_ASYNC31THIRD,
            _aliceOrderManager: POLYGON_ALICE_ORDER_MANAGER,
            _aliceWhitelist: POLYGON_ALICE_WHITELIST,
            _sellTokenAddress: NATIVE_ASSET_ADDRESS,
            _buyTokenAddress: POLYGON_USDC_ADDRESS,
            _chainId: POLYGON_CHAIN_ID
        });
    }
}

// TODO
//contract Async31ThirdWethUsdcTestPolygon is Async31ThirdTestBase {
//    function setUp() public override {
//        __initialize({
//            _version: EnzymeVersion.Current,
//            _async31ThirdAddress: POLYGON_ASYNC31THIRD,
//            _aliceOrderManager: POLYGON_ALICE_ORDER_MANAGER,
//            _aliceWhitelist: POLYGON_ALICE_WHITELIST,
//            _sellTokenAddress: POLYGON_WETH_ADDRESS,
//            _buyTokenAddress: POLYGON_USDC_ADDRESS,
//            _chainId: POLYGON_CHAIN_ID
//        });
//    }
//}

//contract AliceWbtcUsdcTestEthereumV4 is AliceTestBase {
//    function setUp() public override {
//        __initialize({
//            _version: EnzymeVersion.V4,
//            _aliceOrderManagerAddress: ETHEREUM_ALICE_ORDER_MANAGER,
//            _instrumentId: ETHEREUM_ALICE_WBTC_USDC_INSTRUMENT_ID,
//            _chainId: ETHEREUM_CHAIN_ID
//        });
//    }
//}
//
//// The ETH_USDC instrumentID tests native asset handling
//contract AliceEthUsdcTestEthereum is AliceTestBase {
//    function setUp() public override {
//        __initialize({
//            _version: EnzymeVersion.Current,
//            _aliceOrderManagerAddress: ETHEREUM_ALICE_ORDER_MANAGER,
//            _instrumentId: ETHEREUM_ALICE_ETH_USDC_INSTRUMENT_ID,
//            _chainId: ETHEREUM_CHAIN_ID
//        });
//    }
//}
//
//contract AliceEthUsdcTestEthereumV4 is AliceTestBase {
//    function setUp() public override {
//        __initialize({
//            _version: EnzymeVersion.V4,
//            _aliceOrderManagerAddress: ETHEREUM_ALICE_ORDER_MANAGER,
//            _instrumentId: ETHEREUM_ALICE_ETH_USDC_INSTRUMENT_ID,
//            _chainId: ETHEREUM_CHAIN_ID
//        });
//    }
//}
