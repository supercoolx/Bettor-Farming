const { expect } = require("chai");
const { constants, BigNumber } = require("ethers");
// const BN = require('BN');
const { ethers } = require("hardhat");
const { getBlockTime, timeShift, timePass, tokens } = require("../utils/utils");
const dbg = require("debug")("test:farming");

const LIQUIDITY = tokens(2_000_000);
const LIQUIDITY_ONE_TOKEN = tokens(1);
const USDTAMOUNT = tokens(8_000_000);
const APPROVEAMOUNT = tokens(9_999_999);
const ONE_DAY = 86400;
const ONE_WEEK = 604800;
const ONE_MONTH = 2678400;
const SMALLPERIODCOUNT = 4;
const PERIODS_REWARD_AMOUNT = tokens(3_000_000);
const FIRST_PERIOD_REWARD_AMOUNT = tokens(1_500);
const SECOND_PERIOD_REWARD_AMOUNT = tokens(2_000_000);
const AFFILIATEPERCENT = 100; // means 10%
const AFFILIATEPERCENTMAX = 500; // means 50%
const AFFILIATEPERCENTMIDDLE = 200; // means 20%
const POOL1 = 5000000;
const POOL2 = 5000000;
const COND1 = 123456;
const COND2 = 654321;
const COND3 = 333333;
const COND1OUTCOME1WIN = 199;
const COND1OUTCOME1LOSE = 198;
const COND2OUTCOME1WIN = 299;
const COND2OUTCOME1LOSE = 298;
const COND3OUTCOME1WIN = 399;
const COND3OUTCOME1LOSE = 398;
const REINFORCEMENT = constants.WeiPerEther.mul(20000); // 10%
const MARGINALITY = 50000000; // 5%
const INIT_USER_BALANCE = tokens(2000);
const BET_30 = tokens(30);
const BET_100 = tokens(100);
const BET_200 = tokens(200);
const BET_300 = tokens(300);
const BET_400 = tokens(400);
const BET_500 = tokens(500);
const BET_600 = tokens(600);
const BET_1000 = tokens(1000);
const BET_IDs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const BET_1_ID = 1;
const BET_2_ID = 2;
const BET_3_ID = 3;
const BET_4_ID = 4;
const BET_5_ID = 5;
const BET_6_ID = 6;
const BET_7_ID = 7;
const BET_8_ID = 8;
const BET_9_ID = 9;
const BET_10_ID = 10;
const BET_11_ID = 11;
const EVENT_BETREGISTERED = "0x5d73f816a9c8908f42e29294c29d1b1d2b206ff58767588c118fd714e81c9f62";
const EVENT_CLAIMED = "0xf01da32686223933d8a18a391060918c7f11a3648639edd87ae013e2e2731743";

describe("Bettors Farming base test", function () {
  let owner,
    rewardAdmin,
    Alice,
    Bob,
    Clarc,
    Dave,
    Eve,
    Franklin,
    Affiliate_1,
    Affiliate_2,
    Affiliate_3,
    lpOwner,
    oracle,
    mainteiner;
  let core, usdt, lp, math, azurobet;

  const prepare = async () => {
    // test USDT
    {
      const Usdt = await ethers.getContractFactory("TestERC20");
      usdt = await Usdt.deploy();
      dbg("usdt deployed to:", usdt.address);
      await usdt.deployed();
      await usdt.mint(owner.address, USDTAMOUNT);
      await usdt.mint(Alice.address, USDTAMOUNT);
    }
    // nft
    {
      const AzuroBet = await ethers.getContractFactory("AzuroBet");
      azurobet = await upgrades.deployProxy(AzuroBet);
      dbg("azurobet deployed to:", azurobet.address);
      await azurobet.deployed();
      dbg(await azurobet.owner(), "-----1", owner.address);
    }
    // lp
    {
      const LP = await ethers.getContractFactory("LP");
      lp = await upgrades.deployProxy(LP, [usdt.address, azurobet.address, ONE_WEEK]);
      dbg("lp deployed to:", lp.address);
      await lp.deployed();
      dbg(await lp.owner(), "-----2", owner.address);
      await azurobet.setLP(lp.address);
    }
    // Math
    {
      const MathContract = await ethers.getContractFactory("Math");
      math = await upgrades.deployProxy(MathContract);

      dbg("Math deployed to:", math.address);
      const Core = await ethers.getContractFactory("Core");
      core = await upgrades.deployProxy(Core, [REINFORCEMENT, oracle.address, MARGINALITY, math.address]);
      dbg("core deployed to:", core.address);
      await core.deployed();
    }
    // setting up
    {
      await core.connect(owner).setLP(lp.address);
      await lp.changeCore(core.address);

      await usdt.approve(lp.address, APPROVEAMOUNT);
      dbg("Approve done ", APPROVEAMOUNT);

      await lp.addLiquidity(LIQUIDITY);
      expect(await lp.balanceOf(owner.address)).to.equal(LIQUIDITY);

      await lp.addLiquidity(LIQUIDITY_ONE_TOKEN);
      expect(await lp.balanceOf(owner.address)).to.equal(BigNumber.from(LIQUIDITY).add(LIQUIDITY_ONE_TOKEN));

      // send to rewardAdmin and users
      await usdt.transfer(rewardAdmin.address, PERIODS_REWARD_AMOUNT);
      await usdt.transfer(Alice.address, INIT_USER_BALANCE);
      await usdt.transfer(Bob.address, BET_1000);
      await usdt.transfer(Clarc.address, BET_500);
      await usdt.transfer(Dave.address, INIT_USER_BALANCE);
      await usdt.transfer(Eve.address, INIT_USER_BALANCE);
      await usdt.transfer(Franklin.address, INIT_USER_BALANCE);
    }
    // BettorsFarming
    {
      const BETTORSFARMING = await ethers.getContractFactory("BettorsFarming");
      BettorsFarming = await upgrades.deployProxy(BETTORSFARMING, [
        0,
        AFFILIATEPERCENTMAX,
        rewardAdmin.address,
        usdt.address,
        azurobet.address,
        core.address,
      ]);
      dbg("BettorsFarming deployed to:", BettorsFarming.address);
      await BettorsFarming.deployed();
      dbg(await BettorsFarming.owner(), "-----2", owner.address, await getBlockTime(ethers));
      await timePass(ethers, 1);
    }
  };

  const startFarming = async (timeshift, amount) => {
    await usdt.connect(rewardAdmin).approve(BettorsFarming.address, amount);
    await BettorsFarming.connect(rewardAdmin).setOperator(rewardAdmin.address, true);

    // set affiliate and its %
    await BettorsFarming.connect(rewardAdmin).registerAffiliate(Affiliate_1.address);
    await BettorsFarming.connect(rewardAdmin).registerAffiliate(Affiliate_2.address);
    await BettorsFarming.connect(rewardAdmin).registerAffiliate(Affiliate_3.address);
    await BettorsFarming.connect(Affiliate_1).setAffiliatePercent(500);
    await BettorsFarming.connect(Affiliate_2).setAffiliatePercent(200);

    let time_start = (await getBlockTime(ethers)) + 1 + timeshift;
    await BettorsFarming.connect(rewardAdmin).startFarming(time_start, ONE_WEEK, amount);
  };

  const createCondition = async (conditionID, outcomeWIN, outcomeLOSE) => {
    time = await getBlockTime(ethers);
    await core.connect(oracle).createCondition(
      conditionID,
      [POOL2, POOL1],
      [outcomeWIN, outcomeLOSE],
      time + 3600, // + 1 hour
      ethers.utils.formatBytes32String("ipfs")
    );
  };
  const getConditionTime = async (conditionID) => {
    const condition = await core.connect(oracle).getCondition(conditionID);
    console.log(condition.timestamp);
    return condition.timestamp;
  };
  const bet = async (user, conditionID, outcomeID, minOdds, amount, affiliate, expectedBetId) => {
    let deadline = (await getBlockTime(ethers)) + 3600; // + 1 hour
    let lastBetID_BeforeExpress = (await core.lastBetID()).eq(BigNumber.from(0))
      ? BigNumber.from(1)
      : await core.lastBetID();

    await usdt.connect(user).approve(lp.address, USDTAMOUNT);

    let tx = await lp.connect(user).bet(conditionID, amount, outcomeID, deadline, minOdds, affiliate.address);
    let receipt = await tx.wait();
    let express = receipt.events.filter((x) => {
      return x.event == "NewBet";
    });

    expect(express[0].args.betID).to.be.equal(expectedBetId);
  };

  const getClaimedAmount = async (claimTx) => {
    let claimEvent = (await claimTx.wait()).events.filter((x) => {
      return x.topics[0] == EVENT_CLAIMED;
    });
    return claimEvent[0].args.amount;
  };
  const resolveCondition = async (conditionID, outcomeWIN, conditionTime) => {
    await timeShift((await getBlockTime(ethers)) + conditionTime);
    await core.connect(oracle).resolveCondition(conditionID, outcomeWIN);
  };

  beforeEach(async () => {
    [
      owner,
      rewardAdmin,
      Alice,
      Bob,
      Clarc,
      Dave,
      Eve,
      Franklin,
      Affiliate_1,
      Affiliate_2,
      Affiliate_3,
      lpOwner,
      oracle,
      mainteiner,
    ] = await ethers.getSigners();

    await prepare();
    await startFarming(0, FIRST_PERIOD_REWARD_AMOUNT);
    await createCondition(COND1, COND1OUTCOME1WIN, COND1OUTCOME1LOSE);
    await createCondition(COND2, COND2OUTCOME1WIN, COND2OUTCOME1LOSE);
    await timePass(ethers, 1);
    
  });
  it("make simple bet and register it to farming with affiliate check", async function () {
    await bet(Alice, COND1, COND1OUTCOME1WIN, 0, BET_100, Affiliate_1, BET_1_ID);
    await bet(Alice, COND2, COND2OUTCOME1WIN, 0, BET_100, Affiliate_2, BET_2_ID);
    await bet(Alice, COND2, COND2OUTCOME1WIN, 0, BET_100, Affiliate_2, BET_3_ID);

    await resolveCondition(COND1, COND1OUTCOME1LOSE, ONE_DAY);
    await resolveCondition(COND2, COND2OUTCOME1LOSE, ONE_DAY);
    // await resolveCondition(COND2, COND2OUTCOME1LOSE, await getConditionTime(COND2));
    let reBet1 = await BettorsFarming.registerBet(BET_1_ID);
    let reBet2 = await BettorsFarming.registerBet(BET_2_ID);
    let betEv1 = (await reBet1.wait()).events.filter((x) => {
      return x.topics[0] == EVENT_BETREGISTERED;
    });
    let betEv2 = (await reBet2.wait()).events.filter((x) => {
      return x.topics[0] == EVENT_BETREGISTERED;
    });
    expect(betEv1[0].args.betOwnerWallet).to.be.equal(Alice.address);
    expect(betEv1[0].args.betId).to.be.equal(BET_1_ID);
    expect(betEv2[0].args.betOwnerWallet).to.be.equal(Alice.address);
    expect(betEv2[0].args.betId).to.be.equal(BET_2_ID);

    // get farmId
    let farmId = (await BettorsFarming.getCurrentFarmPeriod(await getBlockTime(ethers))).farmId.toString();

    console.log("Total farming reward...", FIRST_PERIOD_REWARD_AMOUNT);

    // get reward amount
    console.log("Alice reward...........", (await BettorsFarming.getRewardByWallet(Alice.address, farmId)).toString());
    console.log(
      "Affiliate_1 reward.....",
      (await BettorsFarming.getRewardByWallet(Affiliate_1.address, farmId)).toString()
    );
    console.log(
      "Affiliate_2 reward.....",
      (await BettorsFarming.getRewardByWallet(Affiliate_2.address, farmId)).toString()
    );

    // can't claim rewards until farm period not passed
    await expect(BettorsFarming.connect(Alice).claimReward(farmId)).to.be.revertedWith("Nothing to claim");
    await expect(BettorsFarming.connect(Affiliate_1).claimReward(farmId)).to.be.revertedWith("Nothing to claim");
    await expect(BettorsFarming.connect(Affiliate_2).claimReward(farmId)).to.be.revertedWith("Nothing to claim");

    // pass farm period
    await timePass(ethers, ONE_WEEK);

    await BettorsFarming.connect(Alice).claimReward(farmId);
    await BettorsFarming.connect(Affiliate_1).claimReward(farmId);
    await BettorsFarming.connect(Affiliate_2).claimReward(farmId);

    // all claimed
    expect(await BettorsFarming.getRewardByWallet(Alice.address, farmId)).to.be.equal(0);
    expect(await BettorsFarming.getRewardByWallet(Affiliate_1.address, farmId)).to.be.equal(0);
    expect(await BettorsFarming.getRewardByWallet(Affiliate_2.address, farmId)).to.be.equal(0);
  });
  it("register 3 bets on 2 affiliates", async function () {
    /**
     Total farming Reward = 1500 
     Affiliate_1 takes 50% (0.5)
     Affiliate_2 takes 20% (0.2)
     
     Stakes:
                   Affiliate_1      Affiliate_2
     Alice     100*1.904761904
     Bob      1000*1.838235529
     Clarc                      500*1.732942614

     Total stakes: 
      1295.1830264 = 
      100*(1.904761904-1) + 1000*(1.838235529-1) + 500*(1.732942614-1)

     Rewards:
     Alice 1500*(100*(1.904761904-1)*(1-0.5))/1295.1830264 = 52.391933353705970092      (odd 1.904761904)
     Bob   1500*(1000*(1.838235529-1)*(1-0.5))/1295.1830264 = 485.395989551704952763    (odd 1.838235529)
     Clarc 1500*(500*(1.732942614-1)*(1-0.2))/1295.1830264 = 339.539323351342523430     (odd 1.732942614)
     Affiliate_1 1500*( 
                            100*(1.904761904-1)*0.5 +                                   (Alice stake)
                            1000*(1.838235529-1)*0.5                                    (Bob stake)
                      )/1295.1830264 = 537.787922905410922855
     Affiliate_2 1500*( 
                            500*(1.732942614-1)*0.2                                     (Clarc stake)
                      )/1295.1830264
     */
    await bet(Alice, COND1, COND1OUTCOME1WIN, 0, BET_100, Affiliate_1, BET_1_ID);
    await bet(Bob, COND2, COND2OUTCOME1WIN, 0, BET_1000, Affiliate_1, BET_2_ID);
    await bet(Clarc, COND2, COND2OUTCOME1WIN, 0, BET_500, Affiliate_2, BET_3_ID);
    
    await resolveCondition(COND1, COND1OUTCOME1LOSE, ONE_DAY);
    await resolveCondition(COND2, COND2OUTCOME1LOSE, ONE_DAY);

    await BettorsFarming.registerBet(BET_1_ID);
    await BettorsFarming.registerBet(BET_2_ID);
    await BettorsFarming.registerBet(BET_3_ID);

    // get farmId
    let farmId = (await BettorsFarming.getCurrentFarmPeriod(await getBlockTime(ethers))).farmId.toString();

    // pass farm period
    await timePass(ethers, ONE_WEEK);

    let AliceClaimTx = await BettorsFarming.connect(Alice).claimReward(farmId);
    let BobClaimTx = await BettorsFarming.connect(Bob).claimReward(farmId);
    let ClarcClaimTx = await BettorsFarming.connect(Clarc).claimReward(farmId);
    let Affiliate_1_Tx = await BettorsFarming.connect(Affiliate_1).claimReward(farmId);
    let Affiliate_2_Tx = await BettorsFarming.connect(Affiliate_2).claimReward(farmId);

    expect(await getClaimedAmount(AliceClaimTx)).to.be.equal("52391933353705970092");
    expect(await getClaimedAmount(BobClaimTx)).to.be.equal("485395989551704952763");
    expect(await getClaimedAmount(ClarcClaimTx)).to.be.equal("339539323351342523430");
    expect(await getClaimedAmount(Affiliate_1_Tx)).to.be.equal("537787922905410922855");
    expect(await getClaimedAmount(Affiliate_2_Tx)).to.be.equal("84884830837835630857");

    expect(
      (await getClaimedAmount(AliceClaimTx))
        .add(await getClaimedAmount(BobClaimTx))
        .add(await getClaimedAmount(ClarcClaimTx))
        .add(await getClaimedAmount(Affiliate_1_Tx))
        .add(await getClaimedAmount(Affiliate_2_Tx))
    ).to.be.lte(FIRST_PERIOD_REWARD_AMOUNT);
  });
  it("register 11 bets from 6 players on 3 affiliates with bets crossed by affiliates", async function () {
    /**
     Total farming Reward = 1500 
     Affiliate_1 takes 50% (0.5)
     Affiliate_2 takes 20% (0.2)
     Affiliate_3 takes  0% (0.0)
     Stakes:
                   Affiliate_1      Affiliate_2      Affiliate_3
     Alice     100*1.904761904
     Bob      1000*1.838235529
     Clarc                      500*1.696161866
     Dave      200*1.887690930  400*1.838621298  600*1.765654140
     Eve       100*1.752933649  300*1.651439458  500*1.607436099
     Franklin  200*1.739895101   30*1.625606792

     Total stakes: 
      2990.36231736 = 
      100*(1.904761904-1) + 1000*(1.838235529-1) + 200*(1.88769093-1) + 100*(1.752933649-1) + 200*(1.739895101-1) + 
      500*(1.696161866-1) + 400*(1.838621298-1) + 300*(1.651439458-1) + 30*(1.625606792-1) + 
      600*(1.76565414-1) + 500*(1.607436099-1)

     Rewards:
     Alice 1500*(100*(1.904761904-1)*(1-0.5))/2990.36231736 = 22.691946860775967680     (odd 1.904761904)
     Bob   1500*(1000*(1.838235529-1)*(1-0.5))/2990.36231736 = 210.234272649950484861   (odd 1.838235529)
     Clarc 1500*(500*(1.696161866-1)*(1-0.2))/2990.36231736 = 139.681107260861327054    (odd 1.696161866)
     Dave  1500*(
                            200*(1.88769093-1)*(1-0.5) +                                (odd 1.88769093)
                            400*(1.838621298-1)*(1-0.2) +                               (odd 1.838621298)
                            600*(1.76565414-1)*(1-0)                                    (odd 1.76565414)
                )/2990.36231736 = 409.575983963468546401
     Eve   1500*(
                            100*(1.752933649-1)*(1-0.5) +                               (odd 1.752933649)
                            300*(1.651439458-1)*(1-0.2) +                               (odd 1.651439458)
                            500*(1.607436099-1)*(1-0)                                   (odd 1.607436099)
                )/2990.36231736 = 249.657139695398131152
     Franklin 1500*(
                            200*(1.739895101-1)*(1-0.5) +                               (odd 1.739895101)
                            30*(1.625606792-1)*(1-0.2)                                  (odd 1.625606792)
                )/2990.36231736 = 446.45462821329296928
     Affiliate_1 1500*(
                            100*(1.904761904-1)*0.5 +                                   (Alice stake)
                            1000*(1.838235529-1)*0.5 +                                  (Bob stake)
                            200*(1.88769093-1)*0.5 +                                    (Dave stake)
                            100*(1.752933649-1)*0.5 +                                   (Eve stake)
                            200*(1.739895101-1)*0.5                                     (Franklin stake)
                )/2990.36231736 = 333.451806855067906987
     Affiliate_2 1500*( 
                            500*(1.696161866-1)*0.2 +                                   (Clarc stake)
                            400*(1.838621298-1)*0.2 +                                   (Dave stake)
                            300*(1.651439458-1)*0.2 +                                   (Eve stake)
                            30*(1.625606792-1)*0.2                                      (Franklin stake)
                )/2990.36231736 = 90.062279893148338933
     Affiliate_3 0% no rewards
     */

    await bet(Alice, COND1, COND1OUTCOME1WIN, 0, BET_100, Affiliate_1, BET_IDs[1]);
    await bet(Bob, COND2, COND2OUTCOME1WIN, 0, BET_1000, Affiliate_1, BET_IDs[2]);
    await bet(Dave, COND1, COND1OUTCOME1WIN, 0, BET_200, Affiliate_1, BET_IDs[3]);
    await bet(Eve, COND2, COND2OUTCOME1WIN, 0, BET_100, Affiliate_1, BET_IDs[4]);
    await bet(Franklin, COND2, COND2OUTCOME1WIN, 0, BET_200, Affiliate_1, BET_IDs[5]);
    await bet(Clarc, COND2, COND2OUTCOME1WIN, 0, BET_500, Affiliate_2, BET_IDs[6]);
    await bet(Dave, COND1, COND1OUTCOME1WIN, 0, BET_400, Affiliate_2, BET_IDs[7]);
    await bet(Eve, COND2, COND2OUTCOME1WIN, 0, BET_300, Affiliate_2, BET_IDs[8]);
    await bet(Franklin, COND2, COND2OUTCOME1WIN, 0, BET_30, Affiliate_2, BET_IDs[9]);
    await bet(Dave, COND1, COND1OUTCOME1WIN, 0, BET_600, Affiliate_3, BET_IDs[10]);
    await bet(Eve, COND2, COND2OUTCOME1WIN, 0, BET_500, Affiliate_3, BET_IDs[11]);

    await resolveCondition(COND1, COND1OUTCOME1LOSE, ONE_DAY);
    await resolveCondition(COND2, COND2OUTCOME1LOSE, ONE_DAY);
    for (const iterator of [...Array(11).keys()]) {
      await BettorsFarming.registerBet(BET_IDs[iterator + 1]);
    }

    // get farmId
    let farmId = (await BettorsFarming.getCurrentFarmPeriod(await getBlockTime(ethers))).farmId.toString();

    // pass farm period
    await timePass(ethers, ONE_WEEK);

    let AliceClaimTx = await BettorsFarming.connect(Alice).claimReward(farmId);
    let BobClaimTx = await BettorsFarming.connect(Bob).claimReward(farmId);
    let ClarcClaimTx = await BettorsFarming.connect(Clarc).claimReward(farmId);
    let DaveClaimTx = await BettorsFarming.connect(Dave).claimReward(farmId);
    let EveClaimTx = await BettorsFarming.connect(Eve).claimReward(farmId);
    let FranklinClaimTx = await BettorsFarming.connect(Franklin).claimReward(farmId);
    let Affiliate_1_Tx = await BettorsFarming.connect(Affiliate_1).claimReward(farmId);
    let Affiliate_2_Tx = await BettorsFarming.connect(Affiliate_2).claimReward(farmId);
    await expect(BettorsFarming.connect(Affiliate_3).claimReward(farmId)).to.be.revertedWith("Nothing to claim");

    expect(await getClaimedAmount(AliceClaimTx)).to.be.equal("22691946860775967680");
    expect(await getClaimedAmount(BobClaimTx)).to.be.equal("210234272649950484861");
    expect(await getClaimedAmount(ClarcClaimTx)).to.be.equal("139681107260861327054");
    expect(await getClaimedAmount(DaveClaimTx)).to.be.equal("409575983963468546401");
    expect(await getClaimedAmount(EveClaimTx)).to.be.equal("249657139695398131152");
    expect(await getClaimedAmount(FranklinClaimTx)).to.be.equal("44645462821329296928");
    expect(await getClaimedAmount(Affiliate_1_Tx)).to.be.equal("333451806855067906987");
    expect(await getClaimedAmount(Affiliate_2_Tx)).to.be.equal("90062279893148338933");

    expect(
      (await getClaimedAmount(AliceClaimTx))
        .add(await getClaimedAmount(BobClaimTx))
        .add(await getClaimedAmount(ClarcClaimTx))
        .add(await getClaimedAmount(DaveClaimTx))
        .add(await getClaimedAmount(EveClaimTx))
        .add(await getClaimedAmount(FranklinClaimTx))
        .add(await getClaimedAmount(Affiliate_1_Tx))
        .add(await getClaimedAmount(Affiliate_2_Tx))
    ).to.be.lte(FIRST_PERIOD_REWARD_AMOUNT);
  });
});
