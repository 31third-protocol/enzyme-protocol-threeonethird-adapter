// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) 31Third <dev@31third.com>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.8.19;

/// @title Async31ThirdPositionLibBase1.sol Contract
/// @author 31Third <dev@31third.com>
/// @notice A persistent contract containing all required storage variables and
/// required functions for a Async31ThirdPositionLib.sol implementation
/// @dev DO NOT EDIT CONTRACT. If new events or storage are necessary, they should be added to
/// a numbered AlicePositionLibBaseXXX that inherits the previous base.
/// e.g., `AlicePositionLibBase2 is Async31ThirdPositionLibBase1.sol`
abstract contract Async31ThirdPositionLibBase1 {
    struct OrderDetails {
        address outgoingAssetAddress;
        address incomingAssetAddress;
        uint256 outgoingAmount;
    }

    event OrderIdAdded(uint256 indexed orderId, OrderDetails orderDetails);

    event OrderIdRemoved(uint256 indexed orderId);

    uint256[] internal orderIds;

    mapping(uint256 orderId => OrderDetails) orderIdToOrderDetails;
}
