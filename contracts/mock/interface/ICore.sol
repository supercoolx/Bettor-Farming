// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

interface ICore {
    event ConditionCreated(uint256 conditionID, uint256 timestamp);
    event ConditionResolved(
        uint256 conditionID,
        uint256 outcomeWin,
        uint256 state,
        uint256 amountForLP
    );
    event ConditionShifted(uint256 conditionID, uint256 newTimestamp);

    function getLockedPayout() external view returns (uint256);

    function createCondition(
        uint256 oracleConditionID,
        uint256[2] memory odds,
        uint256[2] memory outcomes,
        uint256 timestamp,
        bytes32 ipfsHash
    ) external;

    function resolveCondition(uint256 conditionID_, uint256 outcomeWin_)
        external;

    function viewPayout(uint256 tokenID) external view returns (bool, uint256);

    function resolvePayout(uint256 tokenID) external returns (bool, uint256);

    function setLP(address lpAddress_) external;

    function getCurrentReinforcement() external view returns (uint256);

    function putBet(
        uint256 conditionID,
        uint256 amount,
        uint256 outcomeWin,
        uint256 minOdds,
        address affiliate
    )
        external
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function getBetInfo(uint256 betId)
        external
        view
        returns (
            uint256 amount,
            uint256 odds,
            uint256 createdAt,
            address affiliate,
            uint8 conditionState
        );
}
