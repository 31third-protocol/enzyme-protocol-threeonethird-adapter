// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {AddOnUtilsBase} from "tests/utils/bases/AddOnUtilsBase.sol";
import {IPendleV2MarketRegistry} from "tests/interfaces/internal/IPendleV2MarketRegistry.sol";

abstract contract PendleV2Utils is AddOnUtilsBase {
    function __deployPendleV2MarketRegistry(address _pendleOracleAddress) internal returns (IPendleV2MarketRegistry) {
        bytes memory args = abi.encode(_pendleOracleAddress);
        return IPendleV2MarketRegistry(deployCode("PendleV2MarketRegistry.sol", args));
    }

    function __encodePendleV2MarketRegistryUpdate(address _marketAddress, uint32 _duration)
        internal
        pure
        returns (IPendleV2MarketRegistry.UpdateMarketInput[] memory updateMarketInputs_)
    {
        updateMarketInputs_ = new IPendleV2MarketRegistry.UpdateMarketInput[](1);
        updateMarketInputs_[0] =
            IPendleV2MarketRegistry.UpdateMarketInput({marketAddress: _marketAddress, duration: _duration});

        return updateMarketInputs_;
    }
}
