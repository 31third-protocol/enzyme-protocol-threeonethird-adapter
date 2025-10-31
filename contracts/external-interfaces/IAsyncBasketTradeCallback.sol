/*
    This file is part of the Enzyme Protocol.

    (c) 31Third <dev@31third.com>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.9.0;

/// @title IAsyncBasketTradeCallback Interface
/// @author 31Third <dev@31third.com>
interface IAsyncBasketTradeCallback {
    function notifySettle(address _token, uint256 _amount, uint256 _orderId) external returns (bool);
    function notifyCancel(uint256 _orderId) external returns (bool);
}
