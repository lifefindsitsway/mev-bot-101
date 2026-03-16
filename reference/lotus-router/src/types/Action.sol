// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

// ## Action Enumeration
//
// This represents the opcodes for the Lotus Router.
//
// Each option maps to an integer (index zero), and we dispatch based on which
// action is encoded. This allows for tighter packing of calldata.
enum Action {
    Halt,
    SwapUniV2,
    SwapUniV3,
    FlashUniV3,
    TransferERC20,
    TransferFromERC20,
    TransferFromERC721,
    TransferERC6909,
    TransferFromERC6909,
    DepositWETH,
    WithdrawWETH,
    DynCall
}
