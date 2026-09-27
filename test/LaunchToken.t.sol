// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_MetadataAndEntireSupplyToDeployer() public view {
        assertEq(token.name(), "Keyring");
        assertEq(token.symbol(), "KEYR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_ExactTransferPreservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_AllowanceTransferAndInfiniteApproval() public {
        token.approve(ALICE, 100);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 60));
        assertEq(token.allowance(address(this), ALICE), 40);
        assertEq(token.balanceOf(BOB), 60);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 10);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_InsufficientBalanceOrAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_ZeroRecipientReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_NoAdminOrMintEntrypointsEvenForDeployer() public {
        string[9] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory data = abi.encodeWithSignature(selectors[i], ALICE, 100);
            (bool deployerOk,) = address(token).call(data);
            vm.prank(ALICE);
            (bool outsiderOk,) = address(token).call(data);
            assertFalse(deployerOk);
            assertFalse(outsiderOk);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }
}
