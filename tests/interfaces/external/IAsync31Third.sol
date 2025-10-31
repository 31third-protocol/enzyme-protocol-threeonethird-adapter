/*
    This file is part of the Enzyme Protocol.

    (c) 31Third <dev@31third.com>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.9.0;

import "./IAsyncBasketTradeCallback.sol";

/// @title IAsync31Third Interface
/// @author 31Third <dev@31third.com>
interface IAsync31Third {
    struct OrderRequest {
        address sellToken;
        address buyToken;
        uint256 amountToSell;
        uint256 limitAmountToGet;

        // Receiver of the buy token
        // Use address(0) if msg.sender should receive
        address receiver;

        // This contract will get notified on settle or cancel
        // Use msg.sender address if sender should get notified
        // Use address(0) to skip notify
        IAsyncBasketTradeCallback callbackContract;
    }

    struct Order {
        uint256 orderId;
        address user;
        address sellToken;
        address buyToken;
        uint256 amountToSell;
        uint256 limitAmountToGet;
        address receiver;
        IAsyncBasketTradeCallback callbackContract;
        uint256 timestamp;
        uint256 aliceOrderId; // external order id
    }

    function owner() external returns (address owner_);

    function feeBPS() external view returns (uint16 feeBPS_);

    function nextOrderId() external view returns (uint256 orderId_);

    function orders(uint256 _orderId) external view returns(Order memory order_);

    function placeOrder(OrderRequest calldata _order) external payable returns (uint256 orderId_);

    function placeOrders(OrderRequest[] calldata _orderRequests) external payable returns (uint256[] memory);

    function refundOrder(uint256 _orderId) external;
}
