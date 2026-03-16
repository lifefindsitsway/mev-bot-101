// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

interface IUniV3FlashCallback {
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}
