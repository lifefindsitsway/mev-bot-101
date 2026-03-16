// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

contract DynTargetMock {
    event Called(address caller, uint256 value, bytes data);

    bool _shouldThrow = false;

    function setShouldThrow(bool shouldThrow) public {
        _shouldThrow = shouldThrow;
    }

    fallback() external payable {
        require(!_shouldThrow);

        emit Called(msg.sender, msg.value, msg.data);
    }

    receive() external payable {
        require(!_shouldThrow);

        emit Called(msg.sender, msg.value, new bytes(0));
    }
}
