// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Foundation <security@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.6.12;

import {NonUpgradableProxy} from "../../../../utils/0.6.12/NonUpgradableProxy.sol";

/// @title ArbitraryTokenPhasedSharesWrapperProxy Contract
/// @author Enzyme Foundation <security@enzyme.finance>
/// @notice A proxy contract for all ArbitraryTokenPhasedSharesWrapper instances
contract ArbitraryTokenPhasedSharesWrapperProxy is NonUpgradableProxy {
    constructor(bytes memory _constructData, address _lib) public NonUpgradableProxy(_constructData, _lib) {}
}
