// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.0;

// solhint-disable

/**
 * @dev Reverts if `condition` is false, with a revert reason containing `errorCode`. Only codes up to 999 are
 * supported.
 */
function _require(bool condition, uint256 errorCode) pure {
    if (!condition) _revert(errorCode);
}

/**
 * @dev Reverts with a revert reason containing `errorCode`. Only codes up to 999 are supported.
 */
function _revert(uint256 errorCode) pure {
    // We're going to dynamically create a revert string based on the error code, with the following format:
    // 'AZU#{errorCode}'
    // where the code is left-padded with zeroes to three digits (so they range from 000 to 999).
    //
    // We don't have revert strings embedded in the contract to save bytecode size: it takes much less space to store a
    // number (8 to 16 bits) than the individual string characters.
    //
    // The dynamic string creation algorithm that follows could be implemented in Solidity, but assembly allows for a
    // much denser implementation, again saving bytecode size. Given this function unconditionally reverts, this is a
    // safe place to rely on it without worrying about how its usage might affect e.g. memory contents.
    assembly {
        // First, we need to compute the ASCII representation of the error code. We assume that it is in the 0-999
        // range, so we only need to convert three digits. To convert the digits to ASCII, we add 0x30, the value for
        // the '0' character.

        let units := add(mod(errorCode, 10), 0x30)

        errorCode := div(errorCode, 10)
        let tenths := add(mod(errorCode, 10), 0x30)

        errorCode := div(errorCode, 10)
        let hundreds := add(mod(errorCode, 10), 0x30)

        // With the individual characters, we can now construct the full string. The "AZU#" part is a known constant
        // (0x415a5523): we simply shift this by 24 (to provide space for the 3 bytes of the error code), and add the
        // characters to it, each shifted by a multiple of 8.
        // The revert reason is then shifted left by 200 bits (256 minus the length of the string, 7 characters * 8 bits
        // per character = 56) to locate it in the most significant part of the 256 slot (the beginning of a byte
        // array).

        let revertReason := shl(
            200,
            add(
                0x415a5523000000,
                add(add(units, shl(8, tenths)), shl(16, hundreds))
            )
        )

        // We can now encode the reason in memory, which can be safely overwritten as we're about to revert. The encoded
        // message will have the following layout:
        // [ revert reason identifier ] [ string location offset ] [ string length ] [ string contents ]

        // The Solidity revert reason identifier is 0x08c739a0, the function selector of the Error(string) function. We
        // also write zeroes to the next 28 bytes of memory, but those are about to be overwritten.
        mstore(
            0x0,
            0x08c379a000000000000000000000000000000000000000000000000000000000
        )
        // Next is the offset to the location of the string, which will be placed immediately after (20 bytes away).
        mstore(
            0x04,
            0x0000000000000000000000000000000000000000000000000000000000000020
        )
        // The string length is fixed: 7 characters.
        mstore(0x24, 7)
        // Finally, the string itself is stored.
        mstore(0x44, revertReason)

        // Even if the string is only 7 bytes long, we need to return a full 32 byte slot containing it. The length of
        // the encoded message is therefore 4 + 32 + 32 + 32 = 100.
        revert(0, 100)
    }
}

library Errors {
    // LP
    uint256 internal constant EXPIRED_ERROR = 30;
    uint256 internal constant ONLY_LP_OWNER = 31;
    uint256 internal constant ONLY_CORE = 32;
    uint256 internal constant AMOUNT_MUST_BE_NON_ZERO = 33;
    uint256 internal constant LIQUIDITY_REQUEST_EXCEEDED_BALANCE = 34;
    uint256 internal constant LIQUIDITY_REQUEST_EXCEEDED = 35;
    uint256 internal constant NOT_ENOUGH_RESERVE = 36;
    uint256 internal constant PERIOD_NOT_PASSED = 37;
    uint256 internal constant NO_WIN_NO_PRIZE = 38;
    uint256 internal constant INCORRECT_OUTCOME = 41;
    uint256 internal constant TIMELIMIT = 42;
    uint256 internal constant ALREADY_SET = 43;
    uint256 internal constant RESOLVE_NOT_STARTED = 44;
    uint256 internal constant RESOLVE_COMPLETED = 45;
    uint256 internal constant MUST_NOT_HAVE_ACTIVE_DISPUTES = 46;
    uint256 internal constant TIME_TO_RESOLVE_NOT_PASSED = 47;
    uint256 internal constant DISTANT_FUTURE = 48;
    uint256 internal constant LP_INIT = 49;

    // Core
    uint256 internal constant ONLY_ORACLE = 50;
    uint256 internal constant ONLY_MAINTAINER = 51;
    uint256 internal constant ONLY_LP = 52;
    uint256 internal constant TIMESTAMP_CAN_NOT_BE_ZERO = 53;
    uint256 internal constant CONDITION_ALREADY_SET = 54;
    uint256 internal constant BIG_DIFFERENCE = 55;
    uint256 internal constant BETS_TIME_EXCEEDED = 56;
    uint256 internal constant WRONG_OUTCOME = 57;
    uint256 internal constant ODDS_TOO_SMALL = 58;
    uint256 internal constant SMALL_BET = 59;
    uint256 internal constant CANT_ACCEPT_THE_BET = 60;
    uint256 internal constant EVENT_NOT_HAPPENED_YET = 61;
    uint256 internal constant CONDITION_NOT_EXISTS = 62;
    uint256 internal constant CONDITION_CANT_BE_RESOLVE_BEFORE_TIMELIMIT = 63;
    uint256 internal constant NOT_ENOUGH_LIQUIDITY = 64;
}
