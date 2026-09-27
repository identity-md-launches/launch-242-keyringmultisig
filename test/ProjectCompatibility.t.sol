// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KeyringMultisig} from "../src/KeyringMultisig.sol";

/// @dev Models only the factory's constructor caller, without broadcasting or using environment variables.
contract FactoryHarness {
    function deploy() external returns (LaunchToken token, KeyringMultisig multisig) {
        token = new LaunchToken();
        multisig = new KeyringMultisig(address(token));
    }
}

contract ProjectCompatibilityTest is Test {
    function test_FactoryDeploymentKeepsWholeSupplyAndNeedsNoInitialization() public {
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken token, KeyringMultisig multisig) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(multisig)), 0);
        assertEq(address(multisig).balance, 0);
        assertEq(address(multisig.token()), address(token));
        assertEq(multisig.walletCount(), 0);
        assertEq(multisig.createWallet(address(1), address(2), address(3)), 1);
        _assertRuntime(address(token));
        _assertRuntime(address(multisig));
    }

    function test_ConstructorsRejectEth() public {
        vm.deal(address(this), 2 ether);
        LaunchToken token = new LaunchToken();
        bytes memory tokenCode = type(LaunchToken).creationCode;
        bytes memory multisigCode = abi.encodePacked(type(KeyringMultisig).creationCode, abi.encode(address(token)));
        address deployedToken;
        address deployedMultisig;
        assembly ("memory-safe") {
            deployedToken := create(1, add(tokenCode, 32), mload(tokenCode))
            deployedMultisig := create(1, add(multisigCode, 32), mload(multisigCode))
        }
        assertEq(deployedToken, address(0));
        assertEq(deployedMultisig, address(0));
        assertEq(address(this).balance, 2 ether);
    }

    function _assertRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden runtime opcode");
        }
    }
}
