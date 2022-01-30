// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

//import "hardhat/console.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interface/ICore.sol";
import "./interface/IAzuroBet.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./helpers/AzuroErrors.sol";

contract LP is ERC20Upgradeable, OwnableUpgradeable {
    using SafeMath for uint256;

    uint256 public totalReserve;
    uint256 public lockedLiquidity; // pure reserve
    address public token;
    ICore public core;
    IAzuroBet public azuroBet;
    uint256 public bettingLiquidity; // reserve amounts + bets
    uint256 public reinforcementAbility; // should be 50%
    uint256 public oddsDecimals;
    uint256 public totalRewards;
    uint256 public totalBetsAmount;
    uint256 public rewardFeeOdds; // in decimals 10^9

    // LP period length 1 week
    uint256 public periodLen;
    /**
     * @dev init timestamp to work by 7 day intervals
     * LP modes: 1 - in/out | 2 - core
     * LP starts from mode 1
     */
    uint256 public initStartDate;

    /*periods before last change*/
    uint256 public savedPeriods;

    mapping(address => Affiliate) public affiliates;

    struct Affiliate {
        uint256 claimed;
        uint256 amount;
    }

    /**
     * @dev request is a structure for calc total LP withdraw requests value
     * @dev walletRequest is a structure for calc LP withdraw request values of some wallet
     */
    struct request {
        mapping(address => uint256) request;
        uint256 totalValue;
    }

    /**
     * @dev requests by period numbers, all previouse numbers can be deleted
     * @dev period# => request
     */
    mapping(uint256 => request) public requests;

    /**
     * @dev event NewBet created on new bet apeared
     * owner - message sender
     * betID - bet ID
     * conditionId - condition id
     * outcomeId - 1 or 2
     * amount - bet amount in payment tokens
     * odds - kef in decimals 10^9
     * fund1 - funds on 1st outcome
     * fund2 - funds on 2nd outcome
     */
    event NewBet(
        address indexed owner,
        uint256 indexed betID,
        uint256 indexed conditionId,
        uint256 outcomeId,
        uint256 amount,
        uint256 odds,
        uint256 fund1,
        uint256 fund2
    );

    event BetterWin(address indexed better, uint256 tokenId, uint256 amount);
    event LiquidityAdded(address indexed account, uint256 amount);
    event LiquidityRemoved(address indexed account, uint256 amount);
    event LiquidityRequested(
        address indexed requestWallet,
        uint256 requestedValueLP
    );

    modifier ensure(uint256 deadline) {
        _require(deadline >= block.timestamp, Errors.EXPIRED_ERROR);
        _;
    }

    modifier onlyCore() {
        _require(msg.sender == address(core), Errors.ONLY_CORE);
        _;
    }

    function changeCore(address addr) external onlyOwner {
        core = ICore(addr);
    }

    function changeRewardOdds(uint256 newOdds_) external onlyOwner {
        rewardFeeOdds = newOdds_;
    }

    function setAzuroBet(address addr) external onlyOwner {
        azuroBet = IAzuroBet(addr);
    }

    /**
     * init
     */

    function initialize(
        address token_,
        address azuroBetAddress,
        uint256 _periodLen
    ) public virtual initializer {
        _require(token_ != address(0), Errors.LP_INIT);
        __ERC20_init("Azuro LP token", "LP-AZR");
        __Ownable_init();
        token = token_;
        azuroBet = IAzuroBet(azuroBetAddress);
        oddsDecimals = 1000000000;
        rewardFeeOdds = 40000000; // 4%
        reinforcementAbility = oddsDecimals / 2; // 50%
        initStartDate = block.timestamp;
        periodLen = _periodLen;
    }

    /**
     * add some liquidity and get LP tokens in return
     * @param amount - token's amount
     */
    function addLiquidity(uint256 amount) external {
        _require(amount > 0, Errors.AMOUNT_MUST_BE_NON_ZERO);
        TransferHelper.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            amount
        );
        // totalReserve reduced by locked Payouts by executing conditions
        _mint(
            msg.sender,
            totalSupply() == 0
                ? amount
                : (amount * totalSupply()) /
                    (totalReserve - core.getLockedPayout())
        );
        totalReserve += amount;
        emit LiquidityAdded(msg.sender, amount);
    }

    /**
     * @dev makes withdraw liquidity request, inc value for some wallet and inc total requests value
     * request links to next allowed period number, if now 1 period, withdraw at 3 period, if now 2, withdraw at 3
     * can be withdrawn next allowed period number
     * @param valueLP LP tokens amount for withdraw liquidity
     */
    function liquidityRequest(uint256 valueLP) public {
        _require(
            requests[_getCurPeriod() + 2].request[msg.sender] + valueLP <=
                balanceOf(msg.sender),
            Errors.LIQUIDITY_REQUEST_EXCEEDED_BALANCE
        );
        //make withdrawal request in next+1 period
        requests[_getCurPeriod() + 2].request[msg.sender] += valueLP;
        requests[_getCurPeriod() + 2].totalValue += valueLP;
        emit LiquidityRequested(msg.sender, valueLP);
    }

    /**
     * @dev withdraw back liquidity burning LP tokens
     * only according by previouse requests
     * @param amountLP - LP tokens amount to burn
     */
    function withdrawLiquidity(uint256 amountLP) external {
        _require(
            amountLP <= requests[_getCurPeriod()].request[msg.sender] &&
                amountLP <= requests[_getCurPeriod()].totalValue,
            Errors.LIQUIDITY_REQUEST_EXCEEDED
        );

        uint256 withdrawValue = (amountLP * totalReserve) / totalSupply();

        _burn(msg.sender, amountLP);

        TransferHelper.safeTransfer(token, msg.sender, withdrawValue);

        totalReserve -= withdrawValue;

        requests[_getCurPeriod()].request[msg.sender] -= amountLP;
        requests[_getCurPeriod()].totalValue -= amountLP;

        emit LiquidityRemoved(msg.sender, withdrawValue);
    }

    function viewPayout(uint256 tokenId) external view returns (bool, uint256) {
        return (core.viewPayout(tokenId));
    }

    /**
     * @dev show on frontend amount of referral reward
     * @param affiliate_ - address of frontend
     * @return reward - amount of frontend reward fot its traffic
     */
    function pendingReward(address affiliate_)
        public
        view
        returns (uint256 reward)
    {
        Affiliate memory affiliate = affiliates[affiliate_];
        if (affiliate.amount == 0) return 0;
        uint256 toClaim = (totalRewards *
            ((affiliate.amount * oddsDecimals) / totalBetsAmount)) /
            oddsDecimals;
        reward = toClaim - affiliate.claimed;
    }

    /**
     * @dev claim frontend referral reward
     */
    function claimReward() external {
        Affiliate storage affiliate = affiliates[msg.sender];
        uint256 toClaim = (totalRewards *
            ((affiliate.amount * oddsDecimals) / totalBetsAmount)) /
            oddsDecimals;
        uint256 reward = toClaim - affiliate.claimed;
        affiliate.claimed = toClaim;
        TransferHelper.safeTransfer(token, msg.sender, reward);
    }

    function withdrawPayout(uint256 tokenId) external {
        _require(
            azuroBet.ownerOftoken(tokenId) == msg.sender,
            Errors.ONLY_LP_OWNER
        );
        (bool success, uint256 amount) = ICore(core).resolvePayout(tokenId);
        _require(success, Errors.NO_WIN_NO_PRIZE);
        bettingLiquidity = bettingLiquidity.sub(amount);
        TransferHelper.safeTransfer(token, msg.sender, amount);
        emit BetterWin(msg.sender, tokenId, amount);
    }

    function bet(
        uint256 conditionID,
        uint256 amount,
        uint256 outcomeID,
        uint256 deadline,
        uint256 minOdds,
        address affiliate_
    ) external ensure(deadline) returns (uint256) {
        TransferHelper.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            amount
        );
        bettingLiquidity = bettingLiquidity.add(amount);

        if (affiliate_ == address(0x0)) affiliate_ = address(this);

        (uint256 tokenId, uint256 odds, uint256 fund1, uint256 fund2) = ICore(
            core
        ).putBet(conditionID, amount, outcomeID, minOdds, affiliate_);

        azuroBet.mint(msg.sender, tokenId);
        affiliates[affiliate_].amount += amount;
        totalBetsAmount += amount;

        emit NewBet(
            msg.sender,
            tokenId,
            conditionID,
            outcomeID,
            amount,
            odds,
            fund1,
            fund2
        );
        return tokenId;
    }

    function addReserve(uint256 initReserve, uint256 profitReserve)
        external
        onlyCore
    {
        if (profitReserve >= initReserve) {
            // pool win
            uint256 profit = profitReserve - initReserve;
            uint256 affiliatesRewards = (profit * rewardFeeOdds) / oddsDecimals;
            totalReserve = totalReserve.add(
                profit - affiliatesRewards + pendingReward(address(this))
            ); // and add to pool rewards from non-affiliate bets
            totalRewards += affiliatesRewards;
        } else {
            // pool lose
            totalReserve = totalReserve.sub(initReserve - profitReserve);
        }
        bettingLiquidity = bettingLiquidity.sub(profitReserve);
        lockedLiquidity = lockedLiquidity.sub(initReserve);
    }

    // reserve some reinforcement
    function lockReserve(uint256 amount) external onlyCore {
        lockedLiquidity = lockedLiquidity.add(amount);
        bettingLiquidity = bettingLiquidity.add(amount);
        _require(lockedLiquidity < totalReserve, Errors.NOT_ENOUGH_RESERVE);
    }

    /**
     * @dev change period length starting from next period
     * @param newPeriod new PERIOD length
     */

    function changePeriod(uint256 newPeriod) public onlyOwner {
        _require(
            initStartDate > 0 &&
                block.timestamp >= initStartDate + _getPeriodLen(),
            Errors.PERIOD_NOT_PASSED
        );
        // temporary vars needed to clearly set new values
        uint256 newinitStartDate = initStartDate +
            (_getCurPeriod() - savedPeriods + 1) *
            _getPeriodLen();
        uint256 newsavedPeriods = _getCurPeriod();

        initStartDate = newinitStartDate;
        savedPeriods = newsavedPeriods;

        periodLen = newPeriod;
    }

    // reserve some reinforcement
    function getReserve() public view returns (uint256 reserve) {
        return totalReserve;
    }

    function getPossibilityOfReinforcement(uint256 reinforcementAmount)
        public
        view
        returns (bool status)
    {
        return (lockedLiquidity + reinforcementAmount <=
            (reinforcementAbility * totalReserve) / oddsDecimals);
    }

    function getPossibilityOfReinforcementFromCore()
        external
        view
        returns (bool status)
    {
        uint256 reinforcementAmount = ICore(core).getCurrentReinforcement();
        return (lockedLiquidity + reinforcementAmount <=
            (reinforcementAbility * totalReserve) / oddsDecimals);
    }

    /**
     * @dev period length
     */
    function _getPeriodLen() internal view returns (uint256) {
        return periodLen;
    }

    /**
     * @dev get period number from very start
     */
    function _getCurPeriod() internal view returns (uint256) {
        return (
            block.timestamp <= initStartDate
                ? savedPeriods
                : (block.timestamp - initStartDate) /
                    _getPeriodLen() +
                    savedPeriods +
                    (savedPeriods > 0 ? 1 : 0)
        );
    }

    /**
     * @dev get next phase end date for (condition create condition)
     */

    function phase2end() external view returns (uint256) {
        return
            initStartDate +
            (_getCurPeriod() - savedPeriods) *
            _getPeriodLen() +
            _getPeriodLen() *
            2;
    }

    /**
     * @dev get begin dates for current, current+1, current+2 periods
     */
    function getPeriodsDates()
        public
        view
        returns (uint256[3] memory beginDates)
    {
        for (uint256 i = 0; i < 3; i++) {
            beginDates[i] =
                initStartDate +
                (_getCurPeriod() - savedPeriods) *
                _getPeriodLen() +
                _getPeriodLen() *
                i;
        }
    }

    /**
     * @dev geting wallet liquidity according lp token requests
     * @param wallet personal wallet
     * @return beginDates array of three periods begin dates: current, next and next+1
     * @return personal liquidity to withdraw in personal requests array of three periods: current, next and next+1
     * @return total liquidity requests array of three periods: current, next and next+1
     */
    function getLiquidityRequests(address wallet)
        public
        view
        returns (
            uint256[3] memory beginDates,
            uint256[3] memory personal,
            uint256[3] memory total
        )
    {
        beginDates = getPeriodsDates();
        for (uint256 i = 0; i < 3; i++) {
            personal[i] = requests[_getCurPeriod() + i].request[wallet];
            total[i] = requests[_getCurPeriod() + i].totalValue;
        }
    }
}
