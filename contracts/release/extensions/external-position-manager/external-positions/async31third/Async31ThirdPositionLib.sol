// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.
    (c) 31Third <dev@31third.com>
    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.8.19;

import {Address} from "openzeppelin-solc-0.8/utils/Address.sol";
import {IAsync31Third} from "../../../../../external-interfaces/IAsync31Third.sol";
import {IAsyncBasketTradeCallback} from "../../../../../external-interfaces/IAsyncBasketTradeCallback.sol";
import {IERC20} from "../../../../../external-interfaces/IERC20.sol";
import {IWETH} from "../../../../../external-interfaces/IWETH.sol";
import {AddressArrayLib} from "../../../../../utils/0.8.19/AddressArrayLib.sol";
import {Uint256ArrayLib} from "../../../../../utils/0.8.19/Uint256ArrayLib.sol";
import {AssetHelpers} from "../../../../../utils/0.8.19/AssetHelpers.sol";
import {WrappedSafeERC20 as SafeERC20} from "../../../../../utils/0.8.19/open-zeppelin/WrappedSafeERC20.sol";
import {Async31ThirdPositionLibBase1} from "./bases/Async31ThirdPositionLibBase1.sol";
import {IAsync31ThirdPosition} from "./IAsync31ThirdPosition.sol";
import {IExternalPositionProxy} from "../../../../../persistent/external-positions/IExternalPositionProxy.sol";

/// @title Async31ThirdPositionLib.sol Contract
/// @author @author 31Third <dev@31third.com>
/// @notice An External Position library contract for Async31Third positions
contract Async31ThirdPositionLib is IAsync31ThirdPosition, Async31ThirdPositionLibBase1, IAsyncBasketTradeCallback, AssetHelpers {
    using AddressArrayLib for address[];
    using SafeERC20 for IERC20;
    using Uint256ArrayLib for uint256[];

    address private constant NATIVE_ASSET_ADDRESS = 0x0000000000000000000000000000000000000000;
    IAsync31Third private immutable ASYNC31THIRD;
    IWETH private immutable WRAPPED_NATIVE_TOKEN;

    error InvalidActionId();

    error OrderNotSettledOrCancelled();

    constructor(address _async31ThirdAddress, address _wrappedNativeAssetAddress) {
        ASYNC31THIRD = IAsync31Third(_async31ThirdAddress);
        WRAPPED_NATIVE_TOKEN = IWETH(_wrappedNativeAssetAddress);
    }

    /// @notice Initializes the external position
    /// @dev Nothing to initialize for this contract
    function init(bytes memory) external override {}

    /// @notice Receives and executes a call from the Vault
    /// @param _actionData Encoded data to execute the action
    function receiveCallFromVault(bytes memory _actionData) external override {
        (uint256 actionId, bytes memory actionArgs) = abi.decode(_actionData, (uint256, bytes));

        if (actionId == uint256(Actions.PlaceOrder)) {
            __placeOrder(actionArgs);
        } else if (actionId == uint256(Actions.PlaceOrders)) {
            __placeOrders(actionArgs);
        } else if (actionId == uint256(Actions.RefundOrder)) {
            __refundOrder(actionArgs);
        } else if (actionId == uint256(Actions.RefundOrders)) {
            __refundOrders(actionArgs);
        } else if (actionId == uint256(Actions.Sweep)) {
            __sweep(actionArgs);
        } else {
            revert InvalidActionId();
        }
    }

    function notifySettle(address _token, uint256 _amount, uint256 _orderId) external override returns (bool) {
        // First transfer asset, just on success remove order
        __transferAssetBalanceToVault({_asset: IERC20(_token)});
        __removeOrder({_orderId: _orderId});
        return true;
    }

    function notifyCancel(uint256 _orderId) external override returns (bool) {
        // First transfer asset, just on success remove order
        OrderDetails memory orderDetails = getOrderDetails({_orderId: _orderId});
        __transferAssetBalanceToVault({_asset: IERC20(orderDetails.outgoingAssetAddress)});
        __removeOrder({_orderId: _orderId});
        return true;
    }

    /// @dev Helper to place an order on the async basket trade
    function __placeOrder(bytes memory _actionArgs) private {
        IAsync31ThirdPosition.PlaceOrderActionArgs memory placeOrderArgs =
            abi.decode(_actionArgs, (IAsync31ThirdPosition.PlaceOrderActionArgs));

        uint256 nativeAssetAmount;
        if (placeOrderArgs.order.sellToken == NATIVE_ASSET_ADDRESS) {
            // If spendAsset is the native asset, unwrap WETH.
            nativeAssetAmount = placeOrderArgs.order.amountToSell;
            WRAPPED_NATIVE_TOKEN.withdraw(placeOrderArgs.order.amountToSell);
        } else {
            // Approve the spend asset
            IERC20(placeOrderArgs.order.sellToken).safeApprove({
                _spender: address(ASYNC31THIRD),
                _value: placeOrderArgs.order.amountToSell
            });
        }

        uint256 orderId = ASYNC31THIRD.placeOrder{value: nativeAssetAmount}(__convertArgsToOrderRequest(placeOrderArgs.order));
        __addOrder(orderId, placeOrderArgs.order);
    }

    /// @dev Helper to place basket orders on the async basket trade
    function __placeOrders(bytes memory _actionArgs) private {
        IAsync31ThirdPosition.PlaceOrdersActionArgs memory placeOrdersArgs =
                            abi.decode(_actionArgs, (IAsync31ThirdPosition.PlaceOrdersActionArgs));

        uint256 nativeAssetAmount = __approveSpendAssetsOrUnwrap(placeOrdersArgs.orders);
        uint256[] memory orderIds = ASYNC31THIRD.placeOrders{value: nativeAssetAmount}(__convertArgsToOrderRequests(placeOrdersArgs.orders));
        __addOrders(orderIds, placeOrdersArgs.orders);
    }

    function __approveSpendAssetsOrUnwrap(IAsync31ThirdPosition.OrderRequest[] memory _orders) private returns (uint256 nativeAssetAmount_) {
        nativeAssetAmount_ = 0;

        uint256 ordersLength = _orders.length;
        address[] memory assets = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        for (uint256 i; i < ordersLength; i++) {
            if (_orders[i].sellToken == NATIVE_ASSET_ADDRESS) {
                nativeAssetAmount_ += _orders[i].amountToSell;
                WRAPPED_NATIVE_TOKEN.withdraw(_orders[i].amountToSell);
            } else {
                assets = assets.addItem(_orders[i].sellToken);
                amounts = amounts.addItem(_orders[i].amountToSell);
            }
        }

        if (assets.length > 1) {
            (assets, amounts) = __aggregateAssetAmounts(assets, amounts);
        }

        // Approve spend assets as needed
        uint256 approvalsCount = assets.length;
        for (uint256 i; i < approvalsCount; i++) {
            __approveAssetMaxAsNeeded({
                _asset: assets[i],
                _target: address(ASYNC31THIRD),
                _neededAmount: amounts[i]
            });
        }
    }

    function __convertArgsToOrderRequests(IAsync31ThirdPosition.OrderRequest[] memory _orderRequests) private returns(IAsync31Third.OrderRequest[] memory orderRequests_) {
        uint256 orderCount = _orderRequests.length;
        orderRequests_ = new IAsync31Third.OrderRequest[](orderCount);
        for (uint256 i; i < orderCount; i++) {
            orderRequests_[i] = __convertArgsToOrderRequest(_orderRequests[i]);
        }
    }

    function __convertArgsToOrderRequest(IAsync31ThirdPosition.OrderRequest memory _orderRequest) private returns(IAsync31Third.OrderRequest memory orderRequest_) {
        orderRequest_ = IAsync31Third.OrderRequest({
            sellToken: _orderRequest.sellToken,
            buyToken: _orderRequest.buyToken,
            amountToSell: _orderRequest.amountToSell,
            limitAmountToGet: _orderRequest.limitAmountToGet,
            receiver: address(0),
            callbackContract: IAsyncBasketTradeCallback(this)
        });
    }

    /// @dev Helper to sweep balance from settled or cancelled orders  where auto-transfer (notify) failed and clear storage
    function __sweep(bytes memory _actionsArgs) private {
        IAsync31ThirdPosition.SweepActionArgs memory sweepArgs = abi.decode(_actionsArgs, (IAsync31ThirdPosition.SweepActionArgs));

        for (uint256 i; i < sweepArgs.orderIds.length; i++) {
            uint256 orderId = sweepArgs.orderIds[i];

            if (!__isOrderSettledOrCancelled({_orderId: orderId})) {
                revert OrderNotSettledOrCancelled();
            }

            OrderDetails memory orderDetails = getOrderDetails({_orderId: orderId});

            __removeOrder({_orderId: orderId});

            // If the order is settled or cancelled, the EP could have received:
            // The incomingAsset if the order has been settled
            // The outgoingAsset if the order has been cancelled
            __transferAssetBalanceToSender({_asset: IERC20(orderDetails.incomingAssetAddress)});
            __transferAssetBalanceToSender({_asset: IERC20(orderDetails.outgoingAssetAddress)});
        }
    }

    /// @dev Helper to refund an outstanding order
    function __refundOrder(bytes memory _actionsArgs) private {
        IAsync31ThirdPosition.RefundOrderActionArgs memory refundOrderArgs =
            abi.decode(_actionsArgs, (IAsync31ThirdPosition.RefundOrderActionArgs));

        __refundOrderById({_orderId: refundOrderArgs.orderId});
    }

    /// @dev Helper to refund an outstanding orders
    function __refundOrders(bytes memory _actionsArgs) private {
        IAsync31ThirdPosition.RefundOrdersActionArgs memory refundOrdersArgs =
                            abi.decode(_actionsArgs, (IAsync31ThirdPosition.RefundOrdersActionArgs));

        uint256 orderCount = refundOrdersArgs.orderIds.length;
        for (uint256 i; i < orderCount; i++) {
            __refundOrderById({_orderId: refundOrdersArgs.orderIds[i]});
        }
    }

    /// @dev Helper to refund an outstanding order by order id
    function __refundOrderById(uint256 _orderId) private {
        OrderDetails memory orderDetails = getOrderDetails({_orderId: _orderId});

        // Refund the order
        ASYNC31THIRD.refundOrder(_orderId);

        // Return the refunded outgoing asset back to the vault
        IERC20 outgoingAsset = IERC20(orderDetails.outgoingAssetAddress);
        __transferAssetBalanceToVault(outgoingAsset);

        // Remove the order from storage
        __removeOrder({_orderId: _orderId});
    }

    /// @dev Helper to add the orderId to storage
    function __addOrders(uint256[] memory _orderIds, IAsync31ThirdPosition.OrderRequest[] memory _orderRequests) private {
        uint256 orderCount = _orderIds.length;
        for (uint256 i; i < orderCount; i++) {
            __addOrder(_orderIds[i], _orderRequests[i]);
        }
    }

    /// @dev Helper to add the orderId to storage
    function __addOrder(uint256 _orderId, IAsync31ThirdPosition.OrderRequest memory _orderRequest) private {
        OrderDetails memory details = OrderDetails({
            outgoingAssetAddress: _orderRequest.sellToken,
            incomingAssetAddress: _orderRequest.buyToken,
            outgoingAmount: _orderRequest.amountToSell
        });

        orderIds.push(_orderId);
        orderIdToOrderDetails[_orderId] = details;
        emit OrderIdAdded(_orderId, details);
    }

    /// @dev Helper to check whether an order has settled or been cancelled
    function __isOrderSettledOrCancelled(uint256 _orderId) private view returns (bool isSettledOrCancelled_) {
        return ASYNC31THIRD.orders({_orderId: _orderId}).timestamp == 0;
    }

    /// @dev Helper to remove the orderId from storage
    function __removeOrder(uint256 _orderId) private {
        orderIds.removeStorageItem(_orderId);

        // Reset the mapping
        delete orderIdToOrderDetails[_orderId];

        emit OrderIdRemoved(_orderId);
    }

    /// @dev Helper to send the balance of an Alice order asset to the Vault
    function __transferAssetBalanceToSender(IERC20 _asset) private {
        uint256 balance =
            address(_asset) == NATIVE_ASSET_ADDRESS ? address(this).balance : _asset.balanceOf(address(this));

        if (balance > 0) {
            // Transfer the asset
            if (address(_asset) == NATIVE_ASSET_ADDRESS) {
                Address.sendValue(payable(msg.sender), balance);
            } else {
                _asset.safeTransfer(msg.sender, balance);
            }
        }
    }

    /// @dev Helper to send the balance of an Alice order asset to the Vault
    function __transferAssetBalanceToVault(IERC20 _asset) private {
        address vaultProxyAddress = IExternalPositionProxy(address(this)).getVaultProxy();

        uint256 balance =
            address(_asset) == NATIVE_ASSET_ADDRESS ? address(this).balance : _asset.balanceOf(address(this));

        if (balance > 0) {
            // Transfer the asset
            if (address(_asset) == NATIVE_ASSET_ADDRESS) {
                Address.sendValue(payable(vaultProxyAddress), balance);
            } else {
                _asset.safeTransfer(vaultProxyAddress, balance);
            }
        }
    }

    ////////////////////
    // POSITION VALUE //
    ////////////////////

    /// @notice Retrieves the debt assets (negative value) of the external position
    /// @return assets_ Debt assets
    /// @return amounts_ Debt asset amounts
    function getDebtAssets() external view override returns (address[] memory assets_, uint256[] memory amounts_) {}

    /// @notice Retrieves the managed assets (positive value) of the external position
    /// @return assets_ Managed assets
    /// @return amounts_ Managed asset amounts
    /// @dev There are 2 ways that positive value can be contributed to this position
    /// 1. Tokens held by the EP either as a result of order settlements or as a result of order cancellations
    /// 2. Tokens held in pending (unfulfilled and uncancelled) orders
    function getManagedAssets() external view override returns (address[] memory assets_, uint256[] memory amounts_) {
        uint256[] memory orderIdsMem = getOrderIds();

        address[] memory receivableAssets;

        for (uint256 i; i < orderIdsMem.length; i++) {
            OrderDetails memory orderDetails = getOrderDetails({_orderId: orderIdsMem[i]});

            bool settledOrCancelled = __isOrderSettledOrCancelled({_orderId: orderIdsMem[i]});

            // If the order is settled or cancelled, the EP will have received the incomingAsset or the outgoingAsset
            // Incoming assets can be received through order settlements
            // Outgoing assets can be received back through order cancellations
            // We have no way of differentiating between the two, so we must add both to the expected assets
            if (settledOrCancelled) {
                receivableAssets = receivableAssets.addUniqueItem(orderDetails.outgoingAssetAddress);
                receivableAssets = receivableAssets.addUniqueItem(orderDetails.incomingAssetAddress);
            } else {
                // If the order is not settled, value the position for its refundable value
                assets_ = assets_.addItem(
                    orderDetails.outgoingAssetAddress == NATIVE_ASSET_ADDRESS
                        ? address(WRAPPED_NATIVE_TOKEN)
                        : orderDetails.outgoingAssetAddress
                );
                amounts_ = amounts_.addItem(orderDetails.outgoingAmount);
            }
        }

        // Check the balance EP balance of each asset that could be received
        for (uint256 i; i < receivableAssets.length; i++) {
            address receivableAssetAddress = receivableAssets[i];

            uint256 balance = receivableAssetAddress == NATIVE_ASSET_ADDRESS
                ? address(this).balance
                : IERC20(receivableAssetAddress).balanceOf(address(this));

            if (balance == 0) {
                continue;
            }

            assets_ = assets_.addItem(
                receivableAssetAddress == NATIVE_ASSET_ADDRESS
                    ? address(WRAPPED_NATIVE_TOKEN)
                    : receivableAssetAddress
            );
            amounts_ = amounts_.addItem(balance);
        }

        return __aggregateAssetAmounts({_rawAssets: assets_, _rawAmounts: amounts_});
    }

    ///////////////////
    // STATE GETTERS //
    ///////////////////

    /// @notice Get the orderDetails of a specified orderId
    /// @return orderDetails_ The orderDetails
    function getOrderDetails(uint256 _orderId) public view override returns (OrderDetails memory orderDetails_) {
        return orderIdToOrderDetails[_orderId];
    }

    /// @notice Get the pending orderIds of the external position
    /// @return orderIds_ The orderIds
    function getOrderIds() public view override returns (uint256[] memory orderIds_) {
        return orderIds;
    }
}
