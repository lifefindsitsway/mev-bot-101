// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import { BytesCalldata } from "src/types/BytesCalldata.sol";

type UniV3Pool is address;

using { swap, flash } for UniV3Pool global;

uint256 constant swapSelector = 0x128acb0800000000000000000000000000000000000000000000000000000000;
uint256 constant flashSelector = 0x490e6cbc00000000000000000000000000000000000000000000000000000000;

// ## Execute Uniswap V3 Swap
//
// ### Parameters
//
// - pool: The Uniswap V3 pool address.
// - recipient: The receiver of the swap output.
// - zeroForOne: Direction of the trade; "true": zero for one, "false": one for zero.
// - amountSpecified: The "exact" portion of the trade amount (More in Notes).
// - sqrtPriceLimitX96: The Q64.96 representation of the price limit.
// - data: The arbitrary calldata for UniV3 callbacks, if any.
//
// ### Returns
//
// - success: returns True if the flash succeeded.
//
// ### Notes
//
// The `amountSpecified` parameter is positive if the input amount is the
// "exact" amount parameter, but if it is negative, the output amount is the
// "exact" amount parameter.
//
// ### Procedures
//
// 01. Load the free memory pointer.
// 02. Load the `data` length as a 32 bit integer.
// 03. Increment the `data` pointer to the beginning of the bytes.
// 04. Store the `swapSelector`.
// 05. Store the `recipient`.
// 06. Store the `zeroForOne`.
// 07. Store the `amountSpecified`.
// 08. Store the `sqrtPriceLimitX96`.
// 09. Store the `data` offset, relative to the slot after the selector.
// 10. Store the `dataLen`.
// 11. Copy the data from calldata to memory.
// 12. Call the `pool` contract, returning `success` to the caller of this
//     function.
function swap(
    UniV3Pool pool,
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    BytesCalldata data
) returns (bool success) {
    assembly ("memory-safe") {
        let fmp := mload(0x40)

        let dataLen := shr(0xe0, calldataload(data))

        data := add(data, 0x04)

        mstore(add(fmp, 0x00), swapSelector)

        mstore(add(fmp, 0x04), recipient)

        mstore(add(fmp, 0x24), zeroForOne)

        mstore(add(fmp, 0x44), amountSpecified)

        mstore(add(fmp, 0x64), sqrtPriceLimitX96)

        mstore(add(fmp, 0x84), 0xa0)

        mstore(add(fmp, 0xa4), dataLen)

        calldatacopy(add(fmp, 0xc4), data, dataLen)

        success := call(gas(), pool, 0x00, fmp, add(dataLen, 0xe4), 0x00, 0x00)
    }
}

// ## Execute Uniswap V3 Flash Loan
//
// ### Parameters
//
// - pool: The Uniswap V3 pool address.
// - recipient: The receiver of the flash output.
// - amount0: The amount of Token 0 to flash.
// - amount1: The amount of Token 1 to flash.
// - data: The arbitrary calldata for UniV3 callbacks, if any.
//
// ### Returns
//
// - success: returns True if the flash succeeded.
//
// ### Notes
//
// The `amountSpecified` parameter is positive if the input amount is the
// "exact" amount parameter, but if it is negative, the output amount is the
// "exact" amount parameter.
//
// ### Procedures
//
// 01. Load the free memory pointer.
// 02. Load the `data` length as a 32 bit integer.
// 03. Increment the `data` pointer to the beginning of the bytes.
// 04. Store the `flashSelector`.
// 05. Store the `recipient`.
// 06. Store the `amount0`.
// 07. Store the `amount0`.
// 08. Store the `data` offset, relative to the slot after the selector.
// 09. Store the `dataLen`.
// 10. Copy the data from calldata to memory.
// 11. Call the `pool` contract, returning `success` to the caller of this
//     function.
function flash(
    UniV3Pool pool,
    address recipient,
    uint256 amount0,
    uint256 amount1,
    BytesCalldata data
) returns (bool success) {
    assembly ("memory-safe") {
        let fmp := mload(0x40)

        let dataLen := shr(0xe0, calldataload(data))

        data := add(data, 0x04)

        mstore(add(fmp, 0x00), flashSelector)

        mstore(add(fmp, 0x04), recipient)

        mstore(add(fmp, 0x24), amount0)

        mstore(add(fmp, 0x44), amount1)

        mstore(add(fmp, 0x64), 0x80)

        mstore(add(fmp, 0x84), dataLen)

        calldatacopy(add(fmp, 0xa4), data, dataLen)

        success := call(gas(), pool, 0x00, fmp, add(dataLen, 0xc4), 0x00, 0x00)
    }
}
