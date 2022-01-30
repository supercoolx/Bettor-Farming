// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

//import "hardhat/console.sol";
import "./helpers/AzuroErrors.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./Libraries/IMath.sol";
import "./interface/ILP.sol";
import "./interface/ICore.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title This contract register bets and create conditions
contract Core is OwnableUpgradeable, ICore {
    enum conditionState {
        CREATED,
        RESOLVED,
        CANCELED
    }

    struct Bet {
        uint256 conditionID;
        uint256 amount;
        uint256 odds;
        uint256 outcome;
        bool payed;
        uint256 createdAt;
        address affiliate;
    }

    struct Condition {
        uint256 reinforcement;
        uint256[2] fundBank;
        uint256[2] payouts;
        uint256[2] totalNetBets;
        uint256[2] outcomes; // unique outcomes for the condition
        uint256 margin;
        bytes32 ipfsHash;
        uint256 outcomeWin;
        conditionState state;
        uint256 maxPayout; // maximum sum of payouts to be paid on some result
        uint256 timestamp; // after this time user cant put bet on condition
    }

    uint256 public decimals;
    mapping(address => bool) public oracles;
    uint256 public conditionsReinforcementFix; // should be 20k
    mapping(address => bool) public maintainers;
    uint256 public conditionsMargin;

    address public lpAddress;
    address public mathAddress;

    mapping(uint256 => Condition) public conditions;
    mapping(uint256 => Bet) public bets; // tokenID -> BET

    uint256 public lastBetID; //start from 1

    // total payout's locked value - sum of maximum payouts of all execution Condition.
    // on each Condition at betting calculate sum of maximum payouts and put it here
    // after Condition finished on each user payout decrease its value
    uint256 public totalLockedPayout;

    modifier onlyOracle() {
        _require(oracles[msg.sender], Errors.ONLY_ORACLE);
        _;
    }
    modifier onlyMaintainer() {
        _require(maintainers[msg.sender], Errors.ONLY_MAINTAINER);
        _;
    }

    modifier OnlyLP() {
        _require(msg.sender == lpAddress, Errors.ONLY_LP);
        _;
    }

    /**
     * init
     */
    function initialize(
        uint256 reinforcement_,
        address oracle_,
        uint256 margin_,
        address math_
    ) public virtual initializer {
        __Ownable_init();
        oracles[oracle_] = true;
        conditionsMargin = margin_; // in decimals ^9
        conditionsReinforcementFix = reinforcement_; // in token decimals
        decimals = 10**9;
        mathAddress = math_;
    }

    function getLockedPayout() external view override returns (uint256) {
        return totalLockedPayout;
    }

    /**
     * @dev create condition from oracle
     * @param oracleConditionID the current match or game id
     * @param odds start odds array[2] for [team 1, team 2]
     * @param outcomes unique outcome for the condition [outcome 1, outcome 2]
     * @param timestamp time when match starts and bets stopped accepts
     * @param ipfsHash detailed info about math stored in IPFS
     */
    function createCondition(
        uint256 oracleConditionID,
        uint256[2] memory odds,
        uint256[2] memory outcomes,
        uint256 timestamp,
        bytes32 ipfsHash
    ) external override onlyOracle {
        // condition must be ended before next phase end date
        _require(timestamp < ILP(lpAddress).phase2end(), Errors.DISTANT_FUTURE);
        _require(timestamp > 0, Errors.TIMESTAMP_CAN_NOT_BE_ZERO);
        _require(
            ILP(lpAddress).getPossibilityOfReinforcement(
                conditionsReinforcementFix
            ),
            Errors.NOT_ENOUGH_LIQUIDITY
        );

        Condition storage newCondition = conditions[oracleConditionID];
        _require(newCondition.timestamp == 0, Errors.CONDITION_ALREADY_SET);

        newCondition.fundBank[0] =
            (conditionsReinforcementFix * odds[1]) /
            (odds[0] + odds[1]);
        newCondition.fundBank[1] =
            (conditionsReinforcementFix * odds[0]) /
            (odds[0] + odds[1]);

        newCondition.outcomes = outcomes;
        newCondition.reinforcement = conditionsReinforcementFix;
        newCondition.timestamp = timestamp;
        newCondition.ipfsHash = ipfsHash;
        ILP(lpAddress).lockReserve(conditionsReinforcementFix);

        // save new condition link
        newCondition.margin = conditionsMargin; //not used yet
        newCondition.state = conditionState.CREATED;
        emit ConditionCreated(oracleConditionID, timestamp);
    }

    /**
     * @dev register the bet in the core
     * @param conditionID the current match or game
     * @param amount bet amount in tokens
     * @param outcomeWin bet outcome
     * @param minOdds odds slippage
     * @return betID with odds of this bet and updated funds
     * @return odds
     * @return fund1 after bet
     * @return fund2 after bet
     */
    function putBet(
        uint256 conditionID,
        uint256 amount,
        uint256 outcomeWin,
        uint256 minOdds,
        address affiliate
    )
        external
        override
        OnlyLP
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        Condition storage condition = conditions[conditionID];
        _require(
            (condition.fundBank[1] + amount) / condition.fundBank[0] < 10000 &&
                (condition.fundBank[0] + amount) / condition.fundBank[1] <
                10000,
            Errors.BIG_DIFFERENCE
        );
        _require(
            block.timestamp < condition.timestamp,
            Errors.BETS_TIME_EXCEEDED
        );

        _require(
            isOutComeCorrect(conditionID, outcomeWin),
            Errors.WRONG_OUTCOME
        );
        lastBetID += 1;

        uint8 outcomeIndex = (
            outcomeWin == conditions[conditionID].outcomes[0] ? 0 : 1
        );

        uint256 odds = IMath(mathAddress).getOddsFromBanks(
            condition.fundBank[0] +
                condition.totalNetBets[1] -
                condition.payouts[1],
            condition.fundBank[1] +
                condition.totalNetBets[0] -
                condition.payouts[0],
            amount,
            outcomeIndex,
            condition.margin,
            decimals
        );
        _require(odds >= minOdds, Errors.ODDS_TOO_SMALL);
        _require(amount > decimals, Errors.SMALL_BET);

        condition.totalNetBets[outcomeIndex] += amount;

        Bet storage newBet = bets[lastBetID];

        newBet.odds = odds;
        newBet.amount = amount;
        newBet.outcome = outcomeWin;
        newBet.conditionID = conditionID;
        newBet.createdAt = block.timestamp;
        newBet.affiliate = affiliate;

        condition.fundBank[outcomeIndex] =
            condition.fundBank[outcomeIndex] +
            amount;
        condition.payouts[outcomeIndex] += (odds * amount) / decimals;

        // calc maximum payout's value
        uint256 maxPayout = (
            condition.payouts[0] > condition.payouts[1]
                ? condition.payouts[0]
                : condition.payouts[1]
        );
        if (maxPayout > condition.maxPayout) {
            // if new maxPayout greater than previouse saved -> save new value
            // and add greater delta to global totalLockedPayout
            totalLockedPayout += (maxPayout - condition.maxPayout);
            condition.maxPayout = maxPayout;
        }
        //emit FundsChange(newBet.conditionID,condition.fund1Bank, condition.fund2Bank);
        _require(
            maxPayout <= condition.fundBank[0] + condition.fundBank[1],
            Errors.CANT_ACCEPT_THE_BET
        );

        return (lastBetID, odds, condition.fundBank[0], condition.fundBank[1]);
    }

    /**
     * @dev resolve the payout
     * @param tokenID it is betID
     * @return success
     * @return amount of better win
     */
    function resolvePayout(uint256 tokenID)
        external
        override
        OnlyLP
        returns (bool success, uint256 amount)
    {
        Bet storage currentBet = bets[tokenID];

        Condition storage condition = conditions[currentBet.conditionID];

        _require(
            condition.state == conditionState.RESOLVED,
            Errors.EVENT_NOT_HAPPENED_YET
        );

        // if condition resulted (any result)
        // and exists amount of locked payout -> release locked payout from global state
        if (condition.maxPayout != 0) {
            // decrease global totalLockedPayout on payout paid value
            totalLockedPayout -= condition.maxPayout;
            condition.maxPayout = 0;
        }

        (success, amount) = _viewPayout(tokenID);

        if (success && amount > 0) {
            currentBet.payed = true;
        }

        return (success, amount);
    }

    /**
     * @dev resolve condition from oracle
     * @param conditionID - id of the game
     * @param outcomeWin - team win outcome
     */
    function resolveCondition(uint256 conditionID, uint256 outcomeWin)
        external
        override
        onlyOracle
    {
        Condition storage condition = conditions[conditionID];
        _require(condition.timestamp > 0, Errors.CONDITION_NOT_EXISTS);
        _require(
            block.timestamp >= condition.timestamp,
            Errors.CONDITION_CANT_BE_RESOLVE_BEFORE_TIMELIMIT
        );
        _require(
            condition.state == conditionState.CREATED,
            Errors.CONDITION_ALREADY_SET
        );

        _require(
            isOutComeCorrect(conditionID, outcomeWin),
            Errors.WRONG_OUTCOME
        );

        condition.outcomeWin = outcomeWin;

        uint8 outcomeIndex = (outcomeWin == condition.outcomes[0] ? 0 : 1);
        // set the condition state to 'RESOLVED' if bets are only lost 
        if (outcomeIndex == 1) {
            condition.state = conditionState.RESOLVED;
        }
        uint256 bettersPayout;
        bettersPayout = condition.payouts[outcomeIndex];

        uint256 profitReserve = (condition.fundBank[0] +
            condition.fundBank[1]) - bettersPayout;
        ILP(lpAddress).addReserve(condition.reinforcement, profitReserve);
        emit ConditionResolved(
            conditionID,
            outcomeWin,
            uint256(conditionState.RESOLVED),
            profitReserve
        );
    }

    function setLP(address lpAddress_) external override onlyOwner {
        lpAddress = lpAddress_;
    }

    // for test MVP
    function setOracle(address oracle_) external onlyOwner {
        oracles[oracle_] = true;
    }

    function renounceOracle(address oracle_) external onlyOwner {
        oracles[oracle_] = false;
    }

    function viewPayout(uint256 tokenID_)
        external
        view
        override
        returns (bool success, uint256 amount)
    {
        return (_viewPayout(tokenID_));
    }

    function getCondition(uint256 conditionID)
        external
        view
        returns (Condition memory)
    {
        return (conditions[conditionID]);
    }
    
    /**
     * @dev get fundBanks from condition record by conditionID
     */
    function getConditionFunds(uint256 conditionID)
        external
        view
        returns (uint256[2] memory fundBank)
    {
        return (conditions[conditionID].fundBank);
    }

    /**
     * internal view, used resolve payout and external views
     * @param tokenID - NFT token id
     */

    function _viewPayout(uint256 tokenID)
        internal
        view
        returns (bool success, uint256 amount)
    {
        Bet storage currentBet = bets[tokenID];
        Condition storage condition = conditions[currentBet.conditionID];

        if (
            !currentBet.payed &&
            (condition.outcomeWin == condition.outcomes[0]) &&
            (currentBet.outcome == condition.outcomes[0])
        ) {
            uint256 winAmount = (currentBet.odds * currentBet.amount) /
                decimals;
            return (true, winAmount);
        }

        if (
            !currentBet.payed &&
            (condition.outcomeWin == condition.outcomes[1]) &&
            (currentBet.outcome == condition.outcomes[1])
        ) {
            uint256 winAmount = (currentBet.odds * currentBet.amount) /
                decimals;
            return (true, winAmount);
        }

        if (!currentBet.payed && (condition.state == conditionState.CANCELED)) {
            return (true, currentBet.amount);
        }
        return (false, 0);
    }

    /**
     * @dev resolve condition from oracle
     * @param conditionID - id of the game
     * @param amount - tokens to bet
     * @param outcomeWin - team win outcome
     * @return odds for this bet
     */
    function calculateOdds(
        uint256 conditionID,
        uint256 amount,
        uint256 outcomeWin
    ) public view returns (uint256 odds) {
        if (isOutComeCorrect(conditionID, outcomeWin)) {
            uint8 outcomeIndex = (
                outcomeWin == conditions[conditionID].outcomes[0] ? 0 : 1
            );
            odds = IMath(mathAddress).getOddsFromBanks(
                conditions[conditionID].fundBank[0],
                conditions[conditionID].fundBank[1],
                amount,
                outcomeIndex,
                conditions[conditionID].margin,
                decimals
            );
        }
    }

    function getCurrentReinforcement()
        external
        view
        override
        returns (uint256)
    {
        return conditionsReinforcementFix;
    }

    function addMaintainer(address maintainer, bool active) external onlyOwner {
        maintainers[maintainer] = active;
    }

    // set conditionState.CANCELED for cancelled conditions
    function cancel(uint256 conditionID) external onlyMaintainer {
        Condition storage condition = conditions[conditionID];
        _require(condition.timestamp > 0, Errors.CONDITION_NOT_EXISTS);
        _require(
            block.timestamp >= condition.timestamp,
            Errors.CONDITION_CANT_BE_RESOLVE_BEFORE_TIMELIMIT
        );
        _require(
            condition.state == conditionState.CREATED,
            Errors.CONDITION_ALREADY_SET
        );

        condition.state = conditionState.CANCELED;

        ILP(lpAddress).addReserve(condition.reinforcement, 0);
        emit ConditionResolved(
            conditionID,
            0,
            uint256(conditionState.CANCELED),
            0
        );
    }

    function shift(uint256 conditionID, uint256 newTimestamp)
        external
        onlyMaintainer
    {
        conditions[conditionID].timestamp = newTimestamp;
        emit ConditionShifted(conditionID, newTimestamp);
    }

    /**
     * @dev check outcome correctness
     * @param conditionID - condition id
     * @param outcomeWin - outcome to be tested
     */
    function isOutComeCorrect(uint256 conditionID, uint256 outcomeWin)
        public
        view
        returns (bool correct)
    {
        correct = (outcomeWin == conditions[conditionID].outcomes[0] ||
            outcomeWin == conditions[conditionID].outcomes[1]);
    }

    function getBetInfo(uint256 betId)
        external
        view
        override
        returns (
            uint256 amount,
            uint256 odds,
            uint256 createdAt,
            address affiliate,
            uint8 state
        )
    {
        return (
            bets[betId].amount,
            bets[betId].odds,
            bets[betId].createdAt,
            bets[betId].affiliate,
            uint8(conditions[bets[betId].conditionID].state)
        );
    }
}
