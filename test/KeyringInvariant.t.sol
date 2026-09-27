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

    struct ExecutionRecord {
        uint256 count;
        uint256 timestamp;
        uint256 liveMask;
    }

    LaunchToken public immutable token;
    KeyringMultisig public immutable multisig;
    address public constant PAYEE = address(0xF00D);
    address public constant OUTSIDER = address(0xBAD);
    uint256 public constant MAX_WALLETS = 8;
    uint256 public expectedWalletCount;
    mapping(uint256 => address[3]) private owners;
    mapping(uint256 => uint256) public expectedEth;
    mapping(uint256 => uint256) public expectedToken;
    mapping(uint256 => uint256) public expectedProposalCount;
    mapping(uint256 => mapping(uint256 => ExpectedProposal)) private expectedProposals;
    mapping(uint256 => mapping(uint256 => ExecutionRecord)) public executions;
    mapping(bytes4 => uint256) public rejections;
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
            ++expectedWalletCount;
        }
        token.approve(address(multisig), type(uint256).max);
    }

    /// @dev Six invalid layouts and four valid cases, including overlapping owner sets.
    function createWallet(uint256 ownerSeed, uint256 modeSeed) external {
        address[5] memory pool = [address(0xA1), address(0xB1), address(0xC1), address(0xD1), address(0xE1)];
        uint256 start = ownerSeed % pool.length;
        address[3] memory next = [pool[start], pool[(start + 1) % 5], pool[(start + 2) % 5]];
        uint256 mode = modeSeed % 10;
        if (mode < 6) {
            if (mode < 3) next[mode] = address(0);
            else if (mode == 3) next[1] = next[0];
            else if (mode == 4) next[2] = next[0];
            else next[2] = next[1];
            _expectFailure(KeyringMultisig.InvalidOwners.selector);
            multisig.createWallet(next[0], next[1], next[2]);
            return;
        }
        if (expectedWalletCount == MAX_WALLETS) return;
        uint256 id = multisig.createWallet(next[0], next[1], next[2]);
        assertEq(id, ++expectedWalletCount, "wallet ids must advance only on success");
        owners[id] = next;
    }

    function invalidDeposit(uint256 walletSeed, bool isToken, uint256 modeSeed) external {
        uint256 mode = modeSeed % 3;
        uint256 id = mode == 0 ? 0 : mode == 1 ? expectedWalletCount + 1 : _id(walletSeed);
        uint256 amount = mode == 2 ? 0 : 1;
        _expectFailure(mode == 2 ? KeyringMultisig.ZeroAmount.selector : KeyringMultisig.UnknownWallet.selector);
        if (isToken) multisig.depositToken(id, amount);
        else multisig.depositEth{value: amount}(id);
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
        assertTrue(token.transfer(address(multisig), amount));
        donations += amount;
    }

    function propose(uint256 walletSeed, uint256 ownerSeed, bool isToken, uint256 valueSeed)
        external
        returns (uint256)
    {
        uint256 id = _id(walletSeed);
        uint256 value = bound(valueSeed, 1, 120e18);
        if (ownerSeed % 4 == 3) {
            _expectFailure(KeyringMultisig.NotOwner.selector);
            vm.prank(OUTSIDER);
            multisig.propose(id, isToken, PAYEE, value);
            return 0;
        }
        return _propose(id, ownerSeed % 4, isToken, value);
    }

    function confirmOrRevoke(uint256 walletSeed, uint256 proposalSeed, uint256 ownerSeed, bool revoke_) external {
        uint256 id = _id(walletSeed);
        _confirmation(id, _pid(id, proposalSeed), ownerSeed % 4, revoke_);
    }

    function _confirmation(uint256 id, uint256 pid, uint256 ownerIndex, bool revoke_) private {
        ExpectedProposal storage p = expectedProposals[id][pid];
        uint256 bit = 1 << ownerIndex;
        bool confirmed = p.mask & bit != 0;
        bytes4 failure = _activeFailure(id, pid, ownerIndex);
        if (failure == bytes4(0)) {
            if (revoke_ && !confirmed) failure = KeyringMultisig.NotConfirmed.selector;
            if (!revoke_ && confirmed) failure = KeyringMultisig.AlreadyConfirmed.selector;
        }
        _expectFailure(failure);
        vm.prank(_actor(id, ownerIndex));
        if (revoke_) {
            multisig.revoke(id, pid);
        } else {
            multisig.confirm(id, pid);
        }
        if (failure != bytes4(0)) return;
        if (revoke_) p.mask &= ~bit;
        else p.mask |= bit;
    }

    function execute(uint256 walletSeed, uint256 proposalSeed, uint256 ownerSeed) external {
        uint256 id = _id(walletSeed);
        _execute(id, _pid(id, proposalSeed), ownerSeed % 4);
    }

    /// @dev Keeps revocation, reconfirmation, unauthorized calls, and replay attempts reachable
    /// even when random time jumps expire most of the independently generated proposals.
    function proposeAndExecute(uint256 walletSeed, uint256 ownerSeed, bool isToken, uint256 valueSeed) external {
        uint256 id = _id(walletSeed);
        uint256 available = isToken ? expectedToken[id] : expectedEth[id];
        if (available == 0) return;
        uint256 value = bound(valueSeed, 1, available);
        uint256 proposer = ownerSeed % 3;
        uint256 pid = _propose(id, proposer, isToken, value);
        uint256 confirmer = (proposer + 1) % 3;
        _confirmation(id, pid, proposer, false); // Duplicate confirmation must not count twice.
        _confirmation(id, pid, confirmer, true); // Unconfirmed owner cannot revoke.
        _confirmation(id, pid, confirmer, false);
        _confirmation(id, pid, confirmer, true);
        _execute(id, pid, proposer); // Revocation has dropped the live count to one.
        _confirmation(id, pid, confirmer, false);
        _execute(id, pid, 3); // Even a ready proposal requires an owner to execute.
        _execute(id, pid, (proposer + 2) % 3);
        _execute(id, pid, proposer); // Immediate replay with another owner.
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 8 days));
    }

    /// @dev Samples one second before, exactly at, and one second after expiry. Time never retreats.
    function warpToDeadline(uint256 walletSeed, uint256 proposalSeed, uint256 boundarySeed) external {
        uint256 id = _id(walletSeed);
        uint256 count = expectedProposalCount[id];
        if (count == 0) return;
        uint256 pid = proposalSeed % count + 1;
        uint256 timestamp = expectedProposals[id][pid].createdAt + 7 days - 1 + boundarySeed % 3;
        if (timestamp >= block.timestamp) vm.warp(timestamp);
    }

    function assertModel() external view {
        uint256 totalEth;
        uint256 totalToken;
        assertEq(multisig.walletCount(), expectedWalletCount);
        for (uint256 id = 1; id <= expectedWalletCount; ++id) {
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
                assertFalse(multisig.isConfirmed(id, pid, OUTSIDER));
            }
        }
        // ETH enters only through depositEth; only the funding actor is funded with vm.deal.
        assertEq(address(multisig).balance, totalEth);
        assertEq(totalEth, ethIn - ethOut);
        assertGe(token.balanceOf(address(multisig)), totalToken);
        assertEq(token.balanceOf(address(multisig)), totalToken + donations);
        assertEq(totalToken, tokenIn - tokenOut);
        assertEq(PAYEE.balance, ethOut);
        assertEq(token.balanceOf(PAYEE), tokenOut);
        assertEq(token.totalSupply(), 1e27);
    }

    function assertExecutionSafety() external view {
        uint256 totalExecutions;
        for (uint256 id = 1; id <= expectedWalletCount; ++id) {
            for (uint256 pid = 1; pid <= expectedProposalCount[id]; ++pid) {
                ExecutionRecord storage record = executions[id][pid];
                ExpectedProposal storage p = expectedProposals[id][pid];
                assertLe(record.count, 1, "proposal executed twice");
                assertEq(multisig.proposal(id, pid).executed, record.count == 1);
                if (record.count != 0) {
                    assertGe(_popcount(record.liveMask), 2, "execution lacked two live confirmations");
                    assertGe(record.timestamp, p.createdAt);
                    assertLt(record.timestamp, p.createdAt + 7 days, "execution occurred at or after expiry");
                }
                totalExecutions += record.count;
            }
        }
        assertEq(totalExecutions, successfulExecutions);
    }

    function _propose(uint256 id, uint256 ownerIndex, bool isToken, uint256 value) private returns (uint256 pid) {
        vm.prank(owners[id][ownerIndex]);
        pid = multisig.propose(id, isToken, PAYEE, value);
        assertEq(pid, ++expectedProposalCount[id]);
        expectedProposals[id][pid] = ExpectedProposal(PAYEE, value, block.timestamp, 1 << ownerIndex, isToken, false);
    }

    function _execute(uint256 id, uint256 pid, uint256 ownerIndex) private {
        ExpectedProposal storage p = expectedProposals[id][pid];
        bytes4 failure = _activeFailure(id, pid, ownerIndex);
        if (failure == bytes4(0)) {
            if (_popcount(p.mask) < 2) {
                failure = KeyringMultisig.InsufficientConfirmations.selector;
            } else if (p.value > (p.isToken ? expectedToken[id] : expectedEth[id])) {
                failure = KeyringMultisig.InsufficientBalance.selector;
            }
        }
        // Snapshot the independent model before the call, not the contract's cached count.
        uint256 liveMask = p.mask;
        uint256 executedAt = block.timestamp;
        _expectFailure(failure);
        vm.prank(_actor(id, ownerIndex));
        multisig.execute(id, pid);
        if (failure != bytes4(0)) return;
        ExecutionRecord storage record = executions[id][pid];
        ++record.count;
        record.timestamp = executedAt;
        record.liveMask = liveMask;
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

    function _activeFailure(uint256 id, uint256 pid, uint256 ownerIndex) private view returns (bytes4) {
        if (ownerIndex == 3) return KeyringMultisig.NotOwner.selector;
        if (pid == 0 || pid > expectedProposalCount[id]) return KeyringMultisig.UnknownProposal.selector;
        ExpectedProposal storage p = expectedProposals[id][pid];
        if (p.executed) return KeyringMultisig.AlreadyExecuted.selector;
        if (block.timestamp >= p.createdAt + 7 days) return KeyringMultisig.ProposalExpired.selector;
        return bytes4(0);
    }

    function _expectFailure(bytes4 failure) private {
        if (failure == bytes4(0)) return;
        ++rejections[failure];
        vm.expectRevert(failure);
    }

    function _actor(uint256 id, uint256 ownerIndex) private view returns (address) {
        return ownerIndex == 3 ? OUTSIDER : owners[id][ownerIndex];
    }

    function _id(uint256 seed) private view returns (uint256) {
        return seed % expectedWalletCount + 1;
    }

    /// @dev Zero and count + 1 intentionally attempt unknown proposals, including empty wallets.
    function _pid(uint256 id, uint256 seed) private view returns (uint256) {
        return seed % (expectedProposalCount[id] + 2);
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
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.depositEth.selector;
        selectors[1] = handler.depositToken.selector;
        selectors[2] = handler.donateToken.selector;
        selectors[3] = handler.propose.selector;
        selectors[4] = handler.confirmOrRevoke.selector;
        selectors[5] = handler.execute.selector;
        selectors[6] = handler.proposeAndExecute.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.createWallet.selector;
        selectors[9] = handler.invalidDeposit.selector;
        selectors[10] = handler.warpToDeadline.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_WalletAndProposalModelAndAssetConservation() public view {
        handler.assertModel();
    }

    function invariant_ExecutionsAreUniqueAndRequireLiveQuorumBeforeExpiry() public view {
        handler.assertExecutionSafety();
    }

    function test_HandlerCreatesWalletsWhileStateIsLiveAndChecksInvalidInputs() public {
        handler.depositEth(0, 2 ether);
        handler.depositToken(1, 10e18);
        handler.propose(0, 0, false, 1 ether);
        handler.createWallet(0, 6);
        handler.createWallet(1, 7);
        assertEq(handler.expectedWalletCount(), 5);
        for (uint256 mode; mode < 6; ++mode) {
            handler.createWallet(mode, mode);
        }
        assertEq(handler.rejections(KeyringMultisig.InvalidOwners.selector), 6);
        assertEq(handler.expectedWalletCount(), 5);

        for (uint256 mode; mode < 3; ++mode) {
            handler.invalidDeposit(3, false, mode);
            handler.invalidDeposit(4, true, mode);
        }
        assertEq(handler.rejections(KeyringMultisig.UnknownWallet.selector), 4);
        assertEq(handler.rejections(KeyringMultisig.ZeroAmount.selector), 2);

        // New wallets participate in the same ledger and proposal model immediately.
        handler.depositEth(3, 2 ether);
        handler.depositToken(4, 10e18);
        handler.proposeAndExecute(3, 1, false, 1 ether);
        handler.proposeAndExecute(4, 2, true, 5e18);

        handler.propose(0, 3, true, 1); // Non-owner proposal.
        handler.confirmOrRevoke(0, 1, 3, false);
        handler.confirmOrRevoke(0, 1, 3, true);
        handler.execute(0, 1, 3);
        for (uint256 i; i < 2; ++i) {
            uint256 unknownPid = i == 0 ? 0 : 2;
            handler.confirmOrRevoke(0, unknownPid, 0, false);
            handler.confirmOrRevoke(0, unknownPid, 1, true);
            handler.execute(0, unknownPid, 2);
        }
        assertEq(handler.rejections(KeyringMultisig.UnknownProposal.selector), 6);
        assertEq(handler.rejections(KeyringMultisig.NotOwner.selector), 6);
        assertEq(handler.successfulExecutions(), 2);
        _assertInvariants();
    }

    function test_HandlerExercisesBothAssetPayoutsRevocationAndReplay() public {
        handler.depositEth(0, 2 ether);
        handler.depositToken(1, 10e18);
        handler.donateToken(1e18);
        handler.proposeAndExecute(0, 0, false, 1 ether);
        handler.proposeAndExecute(1, 0, true, 5e18);
        assertEq(handler.ethOut(), 1 ether);
        assertEq(handler.tokenOut(), 5e18);
        assertEq(handler.rejections(KeyringMultisig.AlreadyConfirmed.selector), 2);
        assertEq(handler.rejections(KeyringMultisig.NotConfirmed.selector), 2);
        assertEq(handler.rejections(KeyringMultisig.InsufficientConfirmations.selector), 2);
        assertEq(handler.rejections(KeyringMultisig.AlreadyExecuted.selector), 2);
        assertEq(handler.successfulExecutions(), 2);

        // Executed proposals remain immutable even after crossing their former expiry.
        handler.advanceTime(7 days);
        for (uint256 walletSeed; walletSeed < 2; ++walletSeed) {
            handler.confirmOrRevoke(walletSeed, 1, 2, false);
            handler.confirmOrRevoke(walletSeed, 1, 0, true);
            handler.execute(walletSeed, 1, 2);
        }
        assertEq(handler.rejections(KeyringMultisig.AlreadyExecuted.selector), 8);
        _assertInvariants();
    }

    function test_HandlerExecutesOneSecondBeforeExpiryForBothAssets() public {
        _exerciseBoundary(false, 0);
        _exerciseBoundary(true, 0);
        assertEq(handler.successfulExecutions(), 2);
    }

    function test_HandlerRejectsExactlyAtExpiryForBothAssets() public {
        _exerciseBoundary(false, 1);
        _exerciseBoundary(true, 1);
        assertEq(handler.rejections(KeyringMultisig.ProposalExpired.selector), 6);
    }

    function test_HandlerRejectsAfterExpiryForBothAssets() public {
        _exerciseBoundary(false, 2);
        _exerciseBoundary(true, 2);
        assertEq(handler.rejections(KeyringMultisig.ProposalExpired.selector), 6);
    }

    function test_HandlerCanRevokeAllOwnersAndNeedsTwoLiveConfirmationsAgain() public {
        for (uint256 asset; asset < 2; ++asset) {
            bool isToken = asset == 1;
            _fund(asset, isToken, 1 ether);
            uint256 pid = handler.propose(asset, 0, isToken, 1 ether);
            handler.confirmOrRevoke(asset, pid, 1, false);
            handler.confirmOrRevoke(asset, pid, 2, false);
            for (uint256 owner; owner < 3; ++owner) {
                handler.confirmOrRevoke(asset, pid, owner, true);
            }
            handler.execute(asset, pid, 0); // Zero live confirmations.
            handler.confirmOrRevoke(asset, pid, 0, false);
            handler.execute(asset, pid, 1); // Only one live confirmation.
            handler.confirmOrRevoke(asset, pid, 2, false);
            handler.execute(asset, pid, 1); // Executor need not be a confirmer.
            _assertInvariants();
        }
        assertEq(handler.rejections(KeyringMultisig.InsufficientConfirmations.selector), 4);
        assertEq(handler.successfulExecutions(), 2);
    }

    function test_HandlerCannotSpendOtherWalletsOtherAssetsOrUntrackedKeyr() public {
        handler.depositEth(0, 2 ether);
        handler.depositToken(1, 2 ether);
        handler.donateToken(10 ether);
        // Aggregate holdings suffice, but each selected wallet has zero of the requested asset.
        for (uint256 walletSeed; walletSeed < 2; ++walletSeed) {
            bool isToken = walletSeed == 0;
            uint256 pid = handler.propose(walletSeed, 0, isToken, 1 ether);
            handler.confirmOrRevoke(walletSeed, pid, 1, false);
            handler.execute(walletSeed, pid, 2);
            _assertInvariants();
            // A later deposit makes exactly the same proposal executable.
            _fund(walletSeed, isToken, 1 ether);
            handler.execute(walletSeed, pid, 2);
            _assertInvariants();
        }
        assertEq(handler.rejections(KeyringMultisig.InsufficientBalance.selector), 2);
        assertEq(handler.successfulExecutions(), 2);
    }

    function test_HandlerProposalIdsAndConfirmationsStayWalletScoped() public {
        handler.depositEth(0, 1 ether);
        handler.depositToken(1, 1 ether);
        uint256 first = handler.propose(0, 0, false, 1 ether);
        uint256 second = handler.propose(1, 0, true, 1 ether);
        assertEq(first, 1);
        assertEq(second, 1);
        handler.confirmOrRevoke(0, first, 1, false);
        handler.execute(1, second, 2); // Same pid and shared owners, but only one confirmation here.
        handler.confirmOrRevoke(1, second, 1, false);
        handler.confirmOrRevoke(0, first, 1, true);
        handler.execute(0, first, 2);
        handler.execute(1, second, 2); // Revoking in wallet 1 cannot revoke in wallet 2.
        handler.confirmOrRevoke(0, first, 1, false);
        handler.execute(0, first, 2); // Execution in wallet 2 cannot consume wallet 1's pid.
        assertEq(handler.rejections(KeyringMultisig.InsufficientConfirmations.selector), 2);
        assertEq(handler.successfulExecutions(), 2);
        _assertInvariants();
    }

    function _exerciseBoundary(bool isToken, uint256 boundary) private {
        uint256 walletSeed = isToken ? 1 : 0;
        _fund(walletSeed, isToken, 1 ether);
        uint256 pid = handler.propose(walletSeed, 0, isToken, 1 ether);
        handler.confirmOrRevoke(walletSeed, pid, 1, false);
        uint256 createdAt = handler.multisig().proposal(walletSeed + 1, pid).createdAt;
        handler.warpToDeadline(walletSeed, pid - 1, boundary);
        assertEq(block.timestamp, createdAt + 7 days - 1 + boundary);
        handler.execute(walletSeed, pid, 2);
        if (boundary != 0) {
            handler.confirmOrRevoke(walletSeed, pid, 2, false);
            handler.confirmOrRevoke(walletSeed, pid, 0, true);
            assertFalse(handler.multisig().proposal(walletSeed + 1, pid).executed);
            // Expired proposals reserve nothing and do not prevent a fresh proposal spending.
            handler.proposeAndExecute(walletSeed, 0, isToken, 1 ether);
        }
        _assertInvariants();
    }

    function _fund(uint256 walletSeed, bool isToken, uint256 amount) private {
        if (isToken) handler.depositToken(walletSeed, amount);
        else handler.depositEth(walletSeed, amount);
    }

    function _assertInvariants() private view {
        handler.assertModel();
        handler.assertExecutionSafety();
    }
}
