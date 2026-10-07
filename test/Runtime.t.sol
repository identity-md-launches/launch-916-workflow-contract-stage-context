// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {SwarmlingsHook} from "../src/SwarmlingsHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";

contract RuntimeTest is Test, HookDeployer {
    function test_deployableRuntimeAndNoEscapeOpcodes() public {
        Swarmlings token = new Swarmlings();
        SwarmlingsHook hook = deployHook(IPoolManager(address(1)));
        _check(address(token));
        _check(token.mirrorERC721());
        _check(address(hook));
        assertLe(type(Swarmlings).creationCode.length, 49_152);
    }

    function _check(address at) internal view {
        bytes memory code = at.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "escape opcode");
        }
    }
}
