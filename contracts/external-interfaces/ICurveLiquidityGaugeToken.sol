// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Foundation <security@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity >=0.6.0 <0.9.0;

/// @title ICurveLiquidityGaugeToken interface
/// @author Enzyme Foundation <security@enzyme.finance>
/// @notice Common interface functions for all Curve liquidity gauge token contracts
interface ICurveLiquidityGaugeToken {
    function lp_token() external view returns (address);
}
