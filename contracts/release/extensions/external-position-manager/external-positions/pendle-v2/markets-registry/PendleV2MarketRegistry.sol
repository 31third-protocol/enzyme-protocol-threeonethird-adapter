// SPDX-License-Identifier: GPL-3.0

/*
    This file is part of the Enzyme Protocol.

    (c) Enzyme Foundation <security@enzyme.finance>

    For the full license information, please view the LICENSE
    file that was distributed with this source code.
*/

pragma solidity 0.8.19;

import {IDispatcher} from "../../../../../../persistent/dispatcher/IDispatcher.sol";
import {IPendleV2Market} from "../../../../../../external-interfaces/IPendleV2Market.sol";
import {IPendleV2PrincipalToken} from "../../../../../../external-interfaces/IPendleV2PrincipalToken.sol";
import {IPendleV2PyYtLpOracle} from "../../../../../../external-interfaces/IPendleV2PyYtLpOracle.sol";
import {IPendleV2MarketRegistry} from "./IPendleV2MarketRegistry.sol";

/// @title PendleV2MarketRegistry Contract
/// @author Enzyme Foundation <security@enzyme.finance>
/// @notice A contract for the per-user registration of Pendle v2 markets
contract PendleV2MarketRegistry is IPendleV2MarketRegistry {
    event MarketForUserUpdated(address indexed user, address indexed marketAddress, uint32 duration);

    event PtForUserUpdated(address indexed user, address indexed ptAddress, address indexed marketAddress);

    error InsufficientOracleState(bool increaseCardinalityRequired, bool oldestObservationSatisfied);

    IPendleV2PyYtLpOracle private immutable PENDLE_ORACLE;

    mapping(address => mapping(address => uint32)) private userToMarketToOracleDuration;
    mapping(address => mapping(address => address)) private userToPtToLinkedMarket;

    constructor(IPendleV2PyYtLpOracle _pendlePyYtLpOracleAddress) {
        PENDLE_ORACLE = _pendlePyYtLpOracleAddress;
    }

    /// @notice Updates the market registry specific to the caller
    /// @param _updateMarketInputs An array of market config inputs to set
    /// @param _skipValidation True to skip optional validation of _updateMarketInputs
    /// @dev See UpdateMarketInput definition for struct param details
    function updateMarketsForCaller(UpdateMarketInput[] calldata _updateMarketInputs, bool _skipValidation)
        external
        override
    {
        address user = msg.sender;

        for (uint256 i; i < _updateMarketInputs.length; i++) {
            UpdateMarketInput memory marketInput = _updateMarketInputs[i];

            // Does not validate zero-duration, which is a valid oracle deactivation
            if (marketInput.duration > 0 && !_skipValidation) {
                __validateMarketConfig({_marketAddress: marketInput.marketAddress, _duration: marketInput.duration});
            }

            // Store the market duration
            userToMarketToOracleDuration[user][marketInput.marketAddress] = marketInput.duration;
            emit MarketForUserUpdated(user, marketInput.marketAddress, marketInput.duration);

            // Handle PT-market link
            (, IPendleV2PrincipalToken pt,) = IPendleV2Market(marketInput.marketAddress).readTokens();
            bool ptIsLinkedToMarket =
                getPtOracleMarketForUser({_user: user, _ptAddress: address(pt)}) == marketInput.marketAddress;

            if (marketInput.duration > 0) {
                // If new duration is non-zero, cache PT-market link (i.e., always follow the last active market)

                if (!ptIsLinkedToMarket) {
                    userToPtToLinkedMarket[user][address(pt)] = marketInput.marketAddress;
                    emit PtForUserUpdated(user, address(pt), marketInput.marketAddress);
                }
            } else if (ptIsLinkedToMarket) {
                // If the PT's linked market duration is being set to 0, remove link to the market

                // Unlink the PT from the market
                userToPtToLinkedMarket[user][address(pt)] = address(0);
                emit PtForUserUpdated(user, address(pt), address(0));
            }
        }
    }

    /// @dev Helper to validate user-input market config.
    /// Only validates the recommended oracle state,
    /// not whether duration provides a sufficiently secure TWAP price.
    /// src: https://docs.pendle.finance/Developers/Oracles/HowToIntegratePtAndLpOracle.
    function __validateMarketConfig(address _marketAddress, uint32 _duration) private view {
        (bool increaseCardinalityRequired,, bool oldestObservationSatisfied) =
            PENDLE_ORACLE.getOracleState({_market: _marketAddress, _duration: _duration});

        if (increaseCardinalityRequired || !oldestObservationSatisfied) {
            revert InsufficientOracleState(increaseCardinalityRequired, oldestObservationSatisfied);
        }
    }

    ///////////////////
    // STATE GETTERS //
    ///////////////////

    // EXTERNAL

    /// @notice Gets the oracle market and its duration for a principal token, as-registered by the given user
    /// @param _user The user
    /// @param _ptAddress The principal token
    /// @return marketAddress_ The market
    /// @return duration_ The duration
    function getPtOracleMarketAndDurationForUser(address _user, address _ptAddress)
        external
        view
        returns (address marketAddress_, uint32 duration_)
    {
        marketAddress_ = getPtOracleMarketForUser({_user: _user, _ptAddress: _ptAddress});
        duration_ = getMarketOracleDurationForUser({_user: _user, _marketAddress: marketAddress_});

        return (marketAddress_, duration_);
    }

    // PUBLIC

    /// @notice Gets the oracle duration for a market, as-registered by the given user
    /// @param _user The user
    /// @param _marketAddress The market
    /// @return duration_ The duration
    function getMarketOracleDurationForUser(address _user, address _marketAddress)
        public
        view
        returns (uint32 duration_)
    {
        return userToMarketToOracleDuration[_user][_marketAddress];
    }

    /// @notice Gets the linked market for a principal token, as-registered by the given user
    /// @param _user The user
    /// @param _ptAddress The principal token
    /// @return marketAddress_ The market
    function getPtOracleMarketForUser(address _user, address _ptAddress) public view returns (address marketAddress_) {
        return userToPtToLinkedMarket[_user][_ptAddress];
    }
}
