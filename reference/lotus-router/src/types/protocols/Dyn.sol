// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import { BytesCalldata } from "src/types/BytesCalldata.sol";

function dynCall(address target, uint256 value, BytesCalldata data) returns (bool success) {
    assembly ("memory-safe") {
        let fmp := mload(0x40)

        let dataLen := shr(0xe0, calldataload(data))

        data := add(data, 0x04)

        calldatacopy(fmp, data, dataLen)

        success := call(gas(), target, value, fmp, dataLen, 0x00, 0x00)
    }
}
