// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.
    (c) 31Third <dev@31third.com>
    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

import {IExternalPosition} from "../../IExternalPosition.sol";
import {Async31ThirdPositionLibBase1} from "./bases/Async31ThirdPositionLibBase1.sol";

pragma solidity >=0.6.0 <0.9.0;

/// @title IAsync31ThirdPosition.sol Interface
/// @author 31Third <dev@31third.com>
interface IAsync31ThirdPosition is IExternalPosition {
    enum Actions {
        PlaceOrder,
        PlaceOrders,
        RefundOrder,
        RefundOrders,
        Sweep
    }

    struct OrderRequest {
        address sellToken;
        address buyToken;
        uint256 amountToSell;
        uint256 limitAmountToGet;
    }

    struct PlaceOrderActionArgs {
        OrderRequest order;
    }

    struct PlaceOrdersActionArgs {
        OrderRequest[] orders;
    }

    struct RefundOrderActionArgs {
        uint256 orderId;
    }

    struct RefundOrdersActionArgs {
        uint256[] orderIds;
    }

    struct SweepActionArgs {
        uint256[] orderIds;
    }

    function getOrderDetails(uint256 _orderId)
        external
        view
        returns (Async31ThirdPositionLibBase1.OrderDetails memory orderDetails_);

    function getOrderIds() external view returns (uint256[] memory orderIds_);
}
