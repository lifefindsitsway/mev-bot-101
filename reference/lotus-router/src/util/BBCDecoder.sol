// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import { BytesCalldata } from "src/types/BytesCalldata.sol";
import { Ptr } from "src/types/PayloadPointer.sol";
import { ERC20 } from "src/types/protocols/ERC20.sol";
import { ERC6909 } from "src/types/protocols/ERC6909.sol";
import { ERC721 } from "src/types/protocols/ERC721.sol";
import { UniV2Pair } from "src/types/protocols/UniV2Pair.sol";
import { UniV3Pool } from "src/types/protocols/UniV3Pool.sol";
import { WETH } from "src/types/protocols/WETH.sol";

// ## Decoder
//
// Inspired by the calldata schema of BigBrainChad.eth
//
// ### Encoding Overview
//
// Statically sized calldata arguments of 8 bits or less are encoded in place.
//
// Statically sized calldata arguments of 9 to 256 bits are prefixed with their
// byte length (as an 8 bit integer) followed by the argument, compacted to its
// byte length. This is to handle the common case of the majority of bits being
// unoccupied.
//
// Dynamically sized calldata arguments are prefixed with a 32 bit integer
// indicating its byte length, followed by the bytes themselves. This is worth
// exploring in the future as to whether or not the upper bits of the byte
// length are unoccupied enough to justify an encoding as mentioned in the
// statically sized calldata arguments above.
//
// We maintain a running pointer `Ptr`, which is incremented as parameters are
// parsed from calldata. This is because the encoding scheme is tightly packed
// such that the exact position of subsequent parameters is unknown at compile
// time. We do this to ensure tight calldata encoding, as callata is quite
// expensive.
library BBCDecoder {
    uint256 internal constant u8Shr = 0xf8;
    uint256 internal constant u32Shr = 0xe0;

    // ## Decode Uniswap V2 Swap
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - pair: The Uniswap V2 pair address.
    // - amount0Out: The expected output amount for token 0.
    // - amount1Out: The expected output amount for token 1.
    // - to: The receiver of the swap output.
    // - data: The arbitrary calldata for UniV2 callbacks, if any.
    function decodeSwapUniV2(
        Ptr ptr
    )
        internal
        pure
        returns (
            Ptr nextPtr,
            bool canFail,
            UniV2Pair pair,
            uint256 amount0Out,
            uint256 amount1Out,
            address to,
            BytesCalldata data
        )
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            pair := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount0Out := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount1Out := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            to := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u32Shr, calldataload(nextPtr))

            data := nextPtr

            nextPtr := add(nextPtr, 0x04)

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode Uniswap V3 Swap
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - pool: The Uniswap V3 pool address.
    // - recipient: The receiver of the swap output.
    // - zeroForOne: Direction of the trade; "true": zero for one, "false": one for zero.
    // - amountSpecified: The "exact" portion of the trade amount (More in Notes).
    // - sqrtPriceLimitX96: The Q64.96 representation of the price limit.
    // - data: The arbitrary calldata for UniV3 callbacks, if any.
    function decodeSwapUniV3(
        Ptr ptr
    )
        internal
        pure
        returns (
            Ptr nextPtr,
            bool canFail,
            UniV3Pool pool,
            address recipient,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 sqrtPriceLimitX96,
            BytesCalldata data
        )
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            pool := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            recipient := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)

            zeroForOne := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amountSpecified := shr(nextBitShift, calldataload(nextPtr))
            amountSpecified := signextend(sub(nextByteLen, 0x01), amountSpecified)

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            sqrtPriceLimitX96 := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u32Shr, calldataload(nextPtr))

            data := nextPtr

            nextPtr := add(nextPtr, 0x04)

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode Uniswap V3 Flash Loan
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - pool: The Uniswap V3 pool address.
    // - recipient: The receiver of the flash output.
    // - amount0: The amount of Token 0 to flash.
    // - amount1: The amount of Token 1 to flash.
    // - data: The arbitrary calldata for UniV3 callbacks, if any.
    function decodeFlashUniV3(
        Ptr ptr
    )
        internal
        pure
        returns (
            Ptr nextPtr,
            bool canFail,
            UniV3Pool pool,
            address recipient,
            uint256 amount0,
            uint256 amount1,
            BytesCalldata data
        )
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            pool := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            recipient := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount0 := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount1 := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u32Shr, calldataload(nextPtr))

            data := nextPtr

            nextPtr := add(nextPtr, 0x04)

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode ERC20 Transfer
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - token: The ERC20 address.
    // - receiver: The transfer receiver address.
    // - amount: The transfer amount.
    function decodeTransferERC20(
        Ptr ptr
    )
        internal
        pure
        returns (Ptr nextPtr, bool canFail, ERC20 token, address receiver, uint256 amount)
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            token := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            receiver := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode ERC20 TransferFrom
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - token: The ERC20 address.
    // - sender: The transfer sender address.
    // - receiver: The transfer receiver address.
    // - amount: The transfer amount.
    function decodeTransferFromERC20(
        Ptr ptr
    )
        internal
        pure
        returns (
            Ptr nextPtr,
            bool canFail,
            ERC20 token,
            address sender,
            address receiver,
            uint256 amount
        )
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            token := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            sender := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            receiver := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode ERC721 TransferFrom
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - token: The ERC721 address.
    // - sender: The transfer sender address.
    // - receiver: The transfer receiver address.
    // - tokenId: The token ID to transfer.
    function decodeTransferFromERC721(
        Ptr ptr
    )
        internal
        pure
        returns (
            Ptr nextPtr,
            bool canFail,
            ERC721 token,
            address sender,
            address receiver,
            uint256 tokenId
        )
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            token := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            sender := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            receiver := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            tokenId := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode ERC6909 Transfer
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - multitoken: The ERC6909 address.
    // - receiver: The transfer receiver address.
    // - amount: The amount to transfer.
    // - tokenId: The token ID to transfer.
    function decodeTransferERC6909(
        Ptr ptr
    )
        internal
        pure
        returns (
            Ptr nextPtr,
            bool canFail,
            ERC6909 multitoken,
            address receiver,
            uint256 tokenId,
            uint256 amount
        )
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            multitoken := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            receiver := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            tokenId := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode ERC6909 TransferFrom
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - multitoken: The ERC6909 address.
    // - sender: The transfer sender address.
    // - receiver: The transfer receiver address.
    // - amount: The amount to transfer.
    // - tokenId: The token ID to transfer.
    function decodeTransferFromERC6909(
        Ptr ptr
    )
        internal
        pure
        returns (
            Ptr nextPtr,
            bool canFail,
            ERC6909 multitoken,
            address sender,
            address receiver,
            uint256 tokenId,
            uint256 amount
        )
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            multitoken := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            sender := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            receiver := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            tokenId := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            amount := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode WETH Deposit
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - weth: The WETH address.
    // - value: The amount to deposit.
    function decodeDepositWETH(
        Ptr ptr
    ) internal pure returns (Ptr nextPtr, bool canFail, WETH weth, uint256 value) {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            weth := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            value := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode WETH Withdrawal
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - weth: The WETH address.
    // - value: The amount to withdraw.
    function decodeWithdrawWETH(
        Ptr ptr
    ) internal pure returns (Ptr nextPtr, bool canFail, WETH weth, uint256 value) {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            weth := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            value := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
        }
    }

    // ## Decode Dynamic Contract Call
    //
    // ### Parameters
    //
    // - ptr: The running pointer.
    //
    // ### Returns
    //
    // - nextPtr: The updated pointer.
    // - canFail: Boolean indicating whether the call can fail.
    // - target: The call target address.
    // - value: The call value.
    // - data: The call payload.
    function decodeDynCall(
        Ptr ptr
    )
        internal
        pure
        returns (Ptr nextPtr, bool canFail, address target, uint256 value, BytesCalldata data)
    {
        assembly {
            let nextByteLen, nextBitShift
            nextPtr := ptr

            canFail := shr(u8Shr, calldataload(nextPtr))

            nextPtr := add(nextPtr, 0x01)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            target := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u8Shr, calldataload(nextPtr))
            nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
            nextPtr := add(nextPtr, 0x01)

            value := shr(nextBitShift, calldataload(nextPtr))

            nextPtr := add(nextPtr, nextByteLen)
            nextByteLen := shr(u32Shr, calldataload(nextPtr))

            data := nextPtr

            nextPtr := add(nextPtr, 0x04)

            nextPtr := add(nextPtr, nextByteLen)
        }
    }
}
