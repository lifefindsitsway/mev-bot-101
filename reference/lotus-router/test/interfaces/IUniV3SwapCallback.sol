// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

interface IUniV3SwapCallback {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}
