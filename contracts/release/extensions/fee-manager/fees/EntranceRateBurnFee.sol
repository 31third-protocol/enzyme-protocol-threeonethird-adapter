// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Foundation <security@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.6.12;

import {IFeeManager} from "../IFeeManager.sol";
import {EntranceRateFeeBase} from "./utils/EntranceRateFeeBase.sol";

/// @title EntranceRateBurnFee Contract
/// @author Enzyme Foundation <security@enzyme.finance>
/// @notice An EntranceRateFee that burns the fee shares
contract EntranceRateBurnFee is EntranceRateFeeBase {
    constructor(address _feeManager) public EntranceRateFeeBase(_feeManager, IFeeManager.SettlementType.Burn) {}
}
