// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Foundation <security@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity >=0.6.0 <0.9.0;

/// @title IPendleV2MarketRegistry Interface
/// @author Enzyme Foundation <security@enzyme.finance>
interface IPendleV2MarketRegistry {
    /// @param marketAddress The Pendle market address to register
    /// @param duration The TWAP duration to use for marketAddress
    struct UpdateMarketInput {
        address marketAddress;
        uint32 duration;
    }

    function getMarketOracleDurationForUser(address _user, address _marketAddress)
        external
        view
        returns (uint32 duration_);

    function getPtOracleMarketAndDurationForUser(address _user, address _ptAddress)
        external
        view
        returns (address marketAddress_, uint32 duration_);

    function getPtOracleMarketForUser(address _user, address _ptAddress)
        external
        view
        returns (address marketAddress_);

    function updateMarketsForCaller(UpdateMarketInput[] calldata _updateMarketInputs, bool _skipValidation) external;
}
