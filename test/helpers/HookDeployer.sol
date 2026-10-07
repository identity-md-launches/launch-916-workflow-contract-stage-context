// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmlingsHook} from "../../src/SwarmlingsHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../../src/HookFlags.sol";

abstract contract HookDeployer {
    function deployHook(IPoolManager manager) internal returns (SwarmlingsHook hook) {
        bytes memory code = abi.encodePacked(type(SwarmlingsHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (HookFlags.matches(predicted, 0x10cc)) {
                hook = new SwarmlingsHook{salt: salt}(manager);
                require(address(hook) == predicted);
                return hook;
            }
        }
        revert("salt not found");
    }
}
