const { BigNumber } = require("@ethersproject/bignumber");

function makeid(length) {
    var result = [];
    var characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var charactersLength = characters.length;
    for (var i = 0; i < length; i++) {
        result.push(characters.charAt(Math.floor(Math.random() * charactersLength)));
    }
    return result.join("");
}

function getRandomConditionID() {
    return Math.random() * 1000000000;
}

function timeout(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function timePass(ethers, timeToPass) {
    await timeShift((await getBlockTime(ethers)) + timeToPass);
}

async function timeShift(time) {
    await network.provider.send("evm_setNextBlockTimestamp", [time]);
    await network.provider.send("evm_mine");
}

async function getBlockTime(ethers) {
    const blockNumBefore = await ethers.provider.getBlockNumber();
    const blockBefore = await ethers.provider.getBlock(blockNumBefore);
    const time = blockBefore.timestamp;
    return time;
}

function tokens(val) {
    return BigNumber.from(val).mul(BigNumber.from("10").pow(18)).toString();
}

function tokensDec(val, dec) {
    return BigNumber.from(val).mul(BigNumber.from("10").pow(dec)).toString();
}

module.exports = {
    makeid, timeout, getBlockTime, timeShift, timePass, tokens, tokensDec
}
