// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KeyringMultisig} from "../src/KeyringMultisig.sol";

/// @dev Independent model of per-wallet liabilities, proposal fields, and confirmation bitsets.
contract KeyringHandler is Test {
    struct ExpectedProposal {
        address to;
        uint256 value;
        uint256 createdAt;
        uint256 mask;
        bool isToken;
        bool executed;
    }

    LaunchToken public immutable token;
    KeyringMultisig public immutable multisig;
    address public constant PAYEE = address(0xF00D);
    mapping(uint256 => address[3]) private owners;
    mapping(uint256 => uint256) public expectedEth;
    mapping(uint256 => uint256) public expectedToken;
    mapping(uint256 => uint256) public expectedProposalCount;
    mapping(uint256 => mapping(uint256 => ExpectedProposal)) private expectedProposals;
    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public tokenIn;
    uint256 public tokenOut;
    uint256 public donations;
    uint256 public successfulExecutions;

    constructor(LaunchToken token_, KeyringMultisig multisig_) {
        token = token_;
        multisig = multisig_;
        // Shared owners make accidental cross-wallet confirmation reuse observable.
        owners[1] = [address(0xA1), address(0xB1), address(0xC1)];
        owners[2] = [address(0xA1), address(0xB1), address(0xD1)];
        owners[3] = [address(0xC1), address(0xD1), address(0xE1)];
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(multisig.createWallet(owners[id][0], owners[id][1], owners[id][2]), id);
        }
        token.approve(address(multisig), type(uint256).max);
    }

    function depositEth(uint256 walletSeed, uint256 amountSeed) external {
        uint256 id = _id(walletSeed);
        uint256 amount = bound(amountSeed, 1, 10 ether);
        multisig.depositEth{value: amount}(id);
        expectedEth[id] += amount;
        ethIn += amount;
    }

    function depositToken(uint256 walletSeed, uint256 amountSeed) external {
        uint256 id = _id(walletSeed);
        uint256 amount = bound(amountSeed, 1, 100e18);
        multisig.depositToken(id, amount);
        expectedToken[id] += amount;
        tokenIn += amount;
    }

    function donateToken(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 100e18);
        token.transfer(address(multisig), amount);
        donations += amount;
    }

    function propose(uint256 walletSeed, uint256 ownerSeed, bool isToken, uint256 valueSeed) external {
        uint256 id = _id(walletSeed);
        uint256 value = bound(valueSeed, 1, 120e18);
        _propose(id, ownerSeed % 3, isToken, value);
    }

    function confirmOrRevoke(uint256 walletSeed, uint256 proposalSeed, uint256 ownerSeed, bool revoke_) external {
        uint256 id = _id(walletSeed);
        uint256 count = expectedProposalCount[id];
        if (count == 0) return;
        uint256 pid = proposalSeed % count + 1;
        ExpectedProposal storage p = expectedProposals[id][pid];
        if (p.executed || block.timestamp >= p.createdAt + 7 days) return;
        uint256 ownerIndex = ownerSeed % 3;
        uint256 bit = 1 << ownerIndex;
        bool confirmed = p.mask & bit != 0;
        if (revoke_) {
            if (!confirmed) vm.expectRevert(KeyringMultisig.NotConfirmed.selector);
            vm.prank(owners[id][ownerIndex]);
            multisig.revoke(id, pid);
            if (confirmed) p.mask &= ~bit;
        } else {
            if (confirmed) vm.expectRevert(KeyringMultisig.AlreadyConfirmed.selector);
            vm.prank(owners[id][ownerIndex]);
            multisig.confirm(id, pid);
            if (!confirmed) p.mask |= bit;
        }
    }

    function execute(uint256 walletSeed, uint256 proposalSeed, uint256 ownerSeed) external {
        uint256 id = _id(walletSeed);
        uint256 count = expectedProposalCount[id];
        if (count == 0) return;
        _execute(id, proposalSeed % count + 1, ownerSeed % 3);
    }

    /// @dev Guarantees successful payouts are exercised alongside arbitrary invalid attempts.
    function proposeAndExecute(uint256 walletSeed, uint256 ownerSeed, bool isToken, uint256 valueSeed) external {
        uint256 id = _id(walletSeed);
        uint256 available = isToken ? expectedToken[id] : expectedEth[id];
        if (available == 0) return;
        uint256 value = bound(valueSeed, 1, available);
        uint256 proposer = ownerSeed % 3;
        uint256 pid = _propose(id, proposer, isToken, value);
        uint256 confirmer = (proposer + 1) % 3;
        vm.prank(owners[id][confirmer]);
        multisig.confirm(id, pid);
        expectedProposals[id][pid].mask |= 1 << confirmer;
        _execute(id, pid, (proposer + 2) % 3);
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 8 days));
    }

    function assertModel() external view {
        uint256 totalEth;
        uint256 totalToken;
        assertEq(multisig.walletCount(), 3);
        for (uint256 id = 1; id <= 3; ++id) {
            (address[3] memory actualOwners, uint256 ethBalance, uint256 tokenBalance) = multisig.wallet(id);
            assertEq(ethBalance, expectedEth[id], "wallet ETH ledger disagrees with model");
            assertEq(tokenBalance, expectedToken[id], "wallet token ledger disagrees with model");
            for (uint256 i; i < 3; ++i) {
                assertEq(actualOwners[i], owners[id][i]);
            }
            totalEth += ethBalance;
            totalToken += tokenBalance;
            assertEq(multisig.proposalCount(id), expectedProposalCount[id]);
            for (uint256 pid = 1; pid <= expectedProposalCount[id]; ++pid) {
                KeyringMultisig.Proposal memory p = multisig.proposal(id, pid);
                ExpectedProposal storage expected = expectedProposals[id][pid];
                assertEq(p.to, expected.to);
                assertEq(p.value, expected.value);
                assertEq(p.createdAt, expected.createdAt);
                assertEq(p.isToken, expected.isToken);
                assertEq(p.executed, expected.executed);
                assertEq(p.confirmations, _popcount(expected.mask));
                for (uint256 i; i < 3; ++i) {
                    assertEq(multisig.isConfirmed(id, pid, owners[id][i]), expected.mask & (1 << i) != 0);
                }
            }
        }
        assertEq(address(multisig).balance, totalEth);
        assertEq(totalEth, ethIn - ethOut);
        assertGe(token.balanceOf(address(multisig)), totalToken);
        assertEq(token.balanceOf(address(multisig)), totalToken + donations);
        assertEq(totalToken, tokenIn - tokenOut);
        assertEq(PAYEE.balance, ethOut);
        assertEq(token.balanceOf(PAYEE), tokenOut);
        assertEq(token.totalSupply(), 1e27);
    }

    function _propose(uint256 id, uint256 ownerIndex, bool isToken, uint256 value) private returns (uint256 pid) {
        vm.prank(owners[id][ownerIndex]);
        pid = multisig.propose(id, isToken, PAYEE, value);
        assertEq(pid, ++expectedProposalCount[id]);
        expectedProposals[id][pid] = ExpectedProposal(PAYEE, value, block.timestamp, 1 << ownerIndex, isToken, false);
    }

    function _execute(uint256 id, uint256 pid, uint256 ownerIndex) private {
        ExpectedProposal storage p = expectedProposals[id][pid];
        bytes4 failure;
        if (p.executed) {
            failure = KeyringMultisig.AlreadyExecuted.selector;
        } else if (block.timestamp >= p.createdAt + 7 days) {
            failure = KeyringMultisig.ProposalExpired.selector;
        } else if (_popcount(p.mask) < 2) {
            failure = KeyringMultisig.InsufficientConfirmations.selector;
        } else if (p.value > (p.isToken ? expectedToken[id] : expectedEth[id])) {
            failure = KeyringMultisig.InsufficientBalance.selector;
        }
        if (failure != bytes4(0)) vm.expectRevert(failure);
        vm.prank(owners[id][ownerIndex]);
        multisig.execute(id, pid);
        if (failure != bytes4(0)) return;
        p.executed = true;
        if (p.isToken) {
            expectedToken[id] -= p.value;
            tokenOut += p.value;
        } else {
            expectedEth[id] -= p.value;
            ethOut += p.value;
        }
        ++successfulExecutions;
    }

    function _id(uint256 seed) private pure returns (uint256) {
        return seed % 3 + 1;
    }

    function _popcount(uint256 mask) private pure returns (uint256) {
        return (mask & 1) + ((mask >> 1) & 1) + ((mask >> 2) & 1);
    }
}

contract KeyringInvariantTest is Test {
    KeyringHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        LaunchToken token = new LaunchToken();
        KeyringMultisig multisig = new KeyringMultisig(address(token));
        handler = new KeyringHandler(token, multisig);
        token.transfer(address(handler), 1e27);
        vm.deal(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.depositEth.selector;
        selectors[1] = handler.depositToken.selector;
        selectors[2] = handler.donateToken.selector;
        selectors[3] = handler.propose.selector;
        selectors[4] = handler.confirmOrRevoke.selector;
        selectors[5] = handler.execute.selector;
        selectors[6] = handler.proposeAndExecute.selector;
        selectors[7] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_WalletAndProposalModelAndAssetConservation() public view {
        handler.assertModel();
    }

    function test_ModelExercisesBothAssetPayoutsAndOverlappingOwners() public {
        handler.depositEth(0, 2 ether);
        handler.depositToken(1, 10e18);
        handler.donateToken(1e18);
        handler.proposeAndExecute(0, 0, false, 1 ether);
        handler.proposeAndExecute(1, 0, true, 5e18);
        handler.propose(0, 1, true, 1e18);
        handler.confirmOrRevoke(0, 1, 0, false);
        handler.execute(0, 1, 2);
        handler.advanceTime(7 days);
        handler.execute(1, 0, 2);
        handler.assertModel();
        assertEq(handler.successfulExecutions(), 2);
    }
}
