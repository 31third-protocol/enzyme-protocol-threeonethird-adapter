// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) 31Third <dev@31third.com>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.8.19;

import "../../../../../external-interfaces/IAsync31Third.sol";
import {AddressArrayLib} from "../../../../../utils/0.8.19/AddressArrayLib.sol";
import {Uint256ArrayLib} from "../../../../../utils/0.8.19/Uint256ArrayLib.sol";
import {Async31ThirdPositionLibBase1} from "./bases/Async31ThirdPositionLibBase1.sol";
import {IAsync31ThirdPosition} from "./IAsync31ThirdPosition.sol";
import {IAsync31Third} from "../../../../../external-interfaces/IAsync31Third.sol";
import {IERC20} from "../../../../../external-interfaces/IERC20.sol";
import {IExternalPositionParser} from "../../IExternalPositionParser.sol";

/// @title Async31ThirdPositionParser.sol
/// @author @author 31Third <dev@31third.com>
/// @notice Parser for Async31Third Positions
contract Async31ThirdPositionParser is IExternalPositionParser {
    using AddressArrayLib for address[];
    using Uint256ArrayLib for uint256[];

    address private constant NATIVE_ASSET_ADDRESS = 0x0000000000000000000000000000000000000000;
    IAsync31Third private immutable ASYNC31THIRD;
    address private immutable WRAPPED_NATIVE_TOKEN_ADDRESS;

    error InvalidActionId();

    constructor(address _async31ThirdAddress, address _wrappedNativeAssetAddress) {
        ASYNC31THIRD = IAsync31Third(_async31ThirdAddress);
        WRAPPED_NATIVE_TOKEN_ADDRESS = _wrappedNativeAssetAddress;
    }

    /// @notice Parses the assets to send and receive for the callOnExternalPosition
    /// @param _externalPositionAddress The address of the ExternalPositionProxy
    /// @param _actionId The _actionId for the callOnExternalPosition
    /// @param _encodedActionArgs The encoded parameters for the callOnExternalPosition
    /// @return assetsToTransfer_ The assets to be transferred from the Vault
    /// @return amountsToTransfer_ The amounts to be transferred from the Vault
    /// @return assetsToReceive_ The assets to be received at the Vault
    function parseAssetsForAction(address _externalPositionAddress, uint256 _actionId, bytes memory _encodedActionArgs)
        external
        view
        override
        returns (
            address[] memory assetsToTransfer_,
            uint256[] memory amountsToTransfer_,
            address[] memory assetsToReceive_
        )
    {
        if (_actionId == uint256(IAsync31ThirdPosition.Actions.PlaceOrder)) {
            IAsync31ThirdPosition.PlaceOrderActionArgs memory placeOrderArgs =
                abi.decode(_encodedActionArgs, (IAsync31ThirdPosition.PlaceOrderActionArgs));

            assetsToTransfer_ = new address[](1);
            assetsToTransfer_[0] = __parseAsset(placeOrderArgs.order.sellToken);

            amountsToTransfer_ = new uint256[](1);
            amountsToTransfer_[0] = placeOrderArgs.order.amountToSell;
        } else if (_actionId == uint256(IAsync31ThirdPosition.Actions.PlaceOrders)) {
            IAsync31ThirdPosition.PlaceOrdersActionArgs memory placeOrdersArgs =
                                abi.decode(_encodedActionArgs, (IAsync31ThirdPosition.PlaceOrdersActionArgs));

            uint256 ordersLength = placeOrdersArgs.orders.length;
            assetsToTransfer_ = new address[](0);
            amountsToTransfer_ = new uint256[](0);

            for (uint256 i; i < ordersLength; i++) {
                address sellToken = __parseAsset(placeOrdersArgs.orders[i].sellToken);

                uint256 assetIndex = assetsToTransfer_.findIndex(sellToken);
                if (assetIndex == type(uint256).max) {
                    assetsToTransfer_ = assetsToTransfer_.addItem(sellToken);
                    amountsToTransfer_ = amountsToTransfer_.addItem(placeOrdersArgs.orders[i].amountToSell);
                } else {
                    amountsToTransfer_[assetIndex] += placeOrdersArgs.orders[i].amountToSell;
                }
            }
        } else if (_actionId == uint256(IAsync31ThirdPosition.Actions.RefundOrder)) {
            IAsync31ThirdPosition.RefundOrderActionArgs memory refundOrderArgs =
                                abi.decode(_encodedActionArgs, (IAsync31ThirdPosition.RefundOrderActionArgs));

            Async31ThirdPositionLibBase1.OrderDetails memory orderDetails =
                                    IAsync31ThirdPosition(_externalPositionAddress).getOrderDetails(refundOrderArgs.orderId);

            assetsToReceive_ = new address[](1);
            assetsToReceive_[0] = __parseAsset(orderDetails.outgoingAssetAddress);
        } else if (_actionId == uint256(IAsync31ThirdPosition.Actions.RefundOrders)) {
            IAsync31ThirdPosition.RefundOrdersActionArgs memory refundOrdersArgs =
                                abi.decode(_encodedActionArgs, (IAsync31ThirdPosition.RefundOrdersActionArgs));

            uint256 ordersLength = refundOrdersArgs.orderIds.length;
            assetsToReceive_ = new address[](0);

            for (uint256 i; i < ordersLength; i++) {
                Async31ThirdPositionLibBase1.OrderDetails memory orderDetails =
                                        IAsync31ThirdPosition(_externalPositionAddress).getOrderDetails(refundOrdersArgs.orderIds[i]);
                address receiveAsset = __parseAsset(orderDetails.outgoingAssetAddress);
                assetsToReceive_ = assetsToReceive_.addUniqueItem(receiveAsset);
            }
        } else if (_actionId == uint256(IAsync31ThirdPosition.Actions.Sweep)) {
            IAsync31ThirdPosition.SweepActionArgs memory sweepArgs =
                abi.decode(_encodedActionArgs, (IAsync31ThirdPosition.SweepActionArgs));

            // Sweep can return either the outgoing or incoming asset (depending on if order is settled or cancelled) so we need to include both
            for (uint256 i; i < sweepArgs.orderIds.length; i++) {
                Async31ThirdPositionLibBase1.OrderDetails memory orderDetails =
                    IAsync31ThirdPosition(_externalPositionAddress).getOrderDetails(sweepArgs.orderIds[i]);

                uint256 outgoingAssetBalance = orderDetails.outgoingAssetAddress == NATIVE_ASSET_ADDRESS
                    ? _externalPositionAddress.balance
                    : IERC20(orderDetails.outgoingAssetAddress).balanceOf(_externalPositionAddress);
                uint256 incomingAssetBalance = orderDetails.incomingAssetAddress == NATIVE_ASSET_ADDRESS
                    ? _externalPositionAddress.balance
                    : IERC20(orderDetails.incomingAssetAddress).balanceOf(_externalPositionAddress);

                if (outgoingAssetBalance > 0) {
                    assetsToReceive_ = assetsToReceive_.addUniqueItem(
                        __parseAsset(orderDetails.outgoingAssetAddress)
                    );
                }

                if (incomingAssetBalance > 0) {
                    assetsToReceive_ = assetsToReceive_.addUniqueItem(
                        __parseAsset(orderDetails.incomingAssetAddress)
                    );
                }
            }
        } else {
            revert InvalidActionId();
        }

        return (assetsToTransfer_, amountsToTransfer_, assetsToReceive_);
    }

    /// @dev Parses Async31Third Native Asset into the wrapped native asset, otherwise returns the asset unchanged.
    function __parseAsset(address _rawAssetAddress) private view returns (address parsedAssetAddress_) {
        return _rawAssetAddress == NATIVE_ASSET_ADDRESS ? WRAPPED_NATIVE_TOKEN_ADDRESS : _rawAssetAddress;
    }

    /// @notice Parse and validate input arguments to be used when initializing a newly-deployed ExternalPositionProxy
    function parseInitArgs(address, bytes memory) external pure override returns (bytes memory) {
        return "";
    }
}
