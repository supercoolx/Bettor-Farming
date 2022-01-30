// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "./mock/interface/ICore.sol";
import "./mock/interface/IAzuroBet.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

contract BettorsFarming is OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public rewardToken;
    IAzuroBet public azuroNFTToken;
    ICore public core;

    uint256 constant oddsDecimals = 10**9;

    uint16 public defaultPercent; // percent, 100 means 10%, 0 (0%) allowed, 1000 (100%) is max
    uint16 public maxAffiliatePercent; // maximum limit of affiliate percent

    struct Farming {
        uint64 timeStart;
        uint64 periodLength;
        uint128 rewardAmount;
    }

    Farming[] public farms;

    // farm# -> value, total staked at farm
    mapping(uint32 => uint128) public totalStaked;

    struct Stake {
        uint128 amount;
        bool claimed;
    }

    // farm# -> wallet -> {amount, claimed}, wallet staked/claimed in exact farm
    mapping(uint32 => mapping(address => Stake)) public walletStake;

    // affiliate - activated
    mapping(address => bool) public affiliates;

    // affiliate percent settings
    struct PercentSet {
        uint16 percent;
        uint128 setTime;
    }

    // affiliate -> percentSet[], saved percent value and time array
    mapping(address => PercentSet[]) public affiliatePercents;

    // operator - activated
    mapping(address => bool) public operators;

    // betid -> registered, for unique bet registering
    mapping(uint256 => bool) public betRegistered;

    event AffiliatePercentSet(address indexed affiliateWallet, uint16 percent);
    event BetRegistered(address indexed betOwnerWallet, uint256 indexed betId);
    event RewardClaimed(
        address indexed betOwnerWallet,
        uint256 farmId,
        uint256 amount
    );

    modifier onlyOperator() {
        require(operators[msg.sender], "Only period operator allowed");
        _;
    }

    modifier onlyAffiliate() {
        require(affiliates[msg.sender], "Only active Affiliate allowed");
        _;
    }

    function initialize(
        uint16 defaultPercent_,
        uint16 maxAffiliatePercent_,
        address rewardAdmin_,
        address rewardToken_,
        address azuroNFTToken_,
        address core_
    ) public virtual initializer {
        __Ownable_init();
        transferOwnership(rewardAdmin_);
        defaultPercent = defaultPercent_;
        rewardToken = IERC20Upgradeable(rewardToken_);
        operators[rewardAdmin_] = true;
        azuroNFTToken = IAzuroBet(azuroNFTToken_);
        core = ICore(core_);
        maxAffiliatePercent = maxAffiliatePercent_;
    }

    /*************************** admin functions *****************************/
    function setOperator(address newOperator, bool isActive) public onlyOwner {
        operators[newOperator] = isActive;
    }

    /*************************** affiliate functions *****************************/
    /**
     * @dev set affiliate percent, settings will be saved (updated) for caller msg.sender address
     * @param newPercet - percent value
     */
    function setAffiliatePercent(uint16 newPercet) public onlyAffiliate {
        _setAffiliatePercent(msg.sender, newPercet);
        emit AffiliatePercentSet(msg.sender, newPercet);
    }

    /*************************** operator functions **************************/
    function registerAffiliate(address affiliate) public onlyOperator {
        _registerAffiliate(affiliate);
    }

    function startFarming(
        uint64 timeStart,
        uint64 periodLength,
        uint128 rewardAmount
    ) public onlyOperator {
        bool canAdd;

        if (farms.length == 0) {
            canAdd = true;
        } else {
            Farming storage farm = farms[farms.length - 1];
            // periods cannot overlap
            if (timeStart > farm.timeStart + farm.periodLength) {
                canAdd = true;
            }
        }

        if (canAdd) {
            farms.push(Farming(timeStart, periodLength, rewardAmount));
            rewardToken.safeTransferFrom(
                msg.sender,
                address(this),
                rewardAmount
            );
        }
    }

    /*************************** public functions ****************************/
    /**
     * @dev permisionless function registering bet by betId,
     * bet includes link to affiliate, it bet share will staked transparently
     * @param betId - bet id for getting better wallet, optimistic bettor win and affiliate
     */
    function registerBet(uint256 betId) public {
        require(!(betRegistered[betId]), "Bet already registered!");

        // get bet data from core
        (
            uint256 amount,
            uint256 odds,
            uint256 createdAt,
            address affiliate,
            uint8 conditionState
        ) = ICore(core).getBetInfo(betId);
        require(conditionState == 1, "condition is not resolved");
        require(oddsDecimals <= odds, "incorrect odds");
        address bettor = IAzuroBet(azuroNFTToken).ownerOftoken(betId);

        (bool isInPeriod, uint32 farmId) = getCurrentFarmPeriod(createdAt);
        require(isInPeriod, "bet is not in farming period");

        uint16 percent = getAffiliatePercentAtTime(
            affiliate,
            farms[farmId].timeStart
        );

        uint128 affiliateStake = (uint128(amount * (odds - oddsDecimals)) *
            percent) / 1000;
        uint128 bettorStake = (uint128(amount * (odds - oddsDecimals)) *
            (1000 - percent)) / 1000;

        totalStaked[farmId] += uint128(amount * (odds - oddsDecimals));
        walletStake[farmId][bettor].amount += bettorStake;
        walletStake[farmId][affiliate].amount += affiliateStake;

        // activate affiliate (needed for affiliate permissions in setting %)
        _registerAffiliate(affiliate);

        emit BetRegistered(bettor, betId);
    }

    function claimReward(uint32 farmId) public {
        uint256 amount = getRewardByWallet(msg.sender, farmId);
        require(
            (block.timestamp >=
                farms[farmId].timeStart + farms[farmId].periodLength) &&
                amount > 0,
            "Nothing to claim"
        );
        walletStake[farmId][msg.sender].claimed = true;
        rewardToken.transfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, farmId, amount);
    }

    /*************************** public view *********************************/
    /**
     * @dev return period and true if betCreatedAt and now are in the period at the moment
     * @return isInPeriod - is current time in the period
     * @return farmId - return current period ID
     */
    function getCurrentFarmPeriod(uint256 betCreatedAt)
        public
        view
        returns (bool isInPeriod, uint32 farmId)
    {
        if (farms.length > 0) {
            for (uint32 i = uint32(farms.length); i > 0; i--) {
                Farming storage farm = farms[i - 1];
                if (
                    block.timestamp >= farm.timeStart &&
                    block.timestamp <= farm.timeStart + farm.periodLength &&
                    betCreatedAt >= farm.timeStart &&
                    betCreatedAt <= farm.timeStart + farm.periodLength
                ) {
                    return (true, i - 1);
                }
            }
        }
    }

    /**
     * @dev get affiliate percent before passed time, if not records found return default percent value
     * @param affiliateWallet - wallet to get percent
     * @param toTime - find records before this time
     */
    function getAffiliatePercentAtTime(address affiliateWallet, uint128 toTime)
        public
        view
        returns (uint16 newPercet)
    {
        newPercet = defaultPercent;
        for (
            uint256 i = affiliatePercents[affiliateWallet].length;
            i > 0;
            i--
        ) {
            if (affiliatePercents[affiliateWallet][i - 1].setTime < toTime) {
                return affiliatePercents[affiliateWallet][i - 1].percent;
            }
        }
    }

    /**
     * @dev calc reward by wallet at current time
     * @param wallet - request wallet
     * @param farmId - requested farm #
     * @return amount - amount of reward value
     */
    function getRewardByWallet(address wallet, uint32 farmId)
        public
        view
        returns (uint256 amount)
    {
        if (!walletStake[farmId][wallet].claimed) {
            amount =
                (uint256(farms[farmId].rewardAmount) *
                    uint256(walletStake[farmId][wallet].amount)) /
                uint256(totalStaked[farmId]);
        }
    }

    function getBetInfo(uint256 betId)
        public
        view
        returns (
            uint256 amount,
            uint256 odds,
            uint256 createdAt,
            address affiliate,
            uint8 state
        )
    {
        return ICore(core).getBetInfo(betId);
    }

    /*************************** internal functions **************************/

    function _setAffiliatePercent(address affiliateWallet, uint16 newPercet)
        internal
    {
        require(
            newPercet >= 0 && newPercet <= maxAffiliatePercent,
            "percent value incorrect"
        );
        affiliatePercents[affiliateWallet].push(
            PercentSet(newPercet, uint128(block.timestamp))
        );
    }

    function _registerAffiliate(address affiliate) internal {
        if (!affiliates[affiliate]) {
            affiliates[address(affiliate)] = true;
        }
    }
}
