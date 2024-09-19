// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Foundation <security@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.6.12;

import {ISolvV2BondBuyerPosition} from "../ISolvV2BondBuyerPosition.sol";

/// @title SolvV2BondBuyerPositionLibBase1 Contract
/// @author Enzyme Foundation <security@enzyme.finance>
/// @notice A persistent contract containing all required storage variables and
/// required functions for a SolvV2BondBuyerPositionLib implementation
/// @dev DO NOT EDIT CONTRACT. If new events or storage are necessary, they should be added to
/// a numbered SolvV2BondBuyerPositionLibBaseXXX that inherits the previous base.
/// e.g., `SolvV2BondBuyerPositionLibBase2 is SolvV2BondBuyerPositionLibBase1`
contract SolvV2BondBuyerPositionLibBase1 {
    event VoucherTokenIdAdded(address indexed voucher, uint32 indexed tokenId);

    event VoucherTokenIdRemoved(address indexed voucher, uint32 indexed tokenId);

    ISolvV2BondBuyerPosition.VoucherTokenId[] internal voucherTokenIds;
}
