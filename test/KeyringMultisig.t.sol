// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KeyringMultisig} from "../src/KeyringMultisig.sol";
import {Recipient, TestToken} from "./helpers/Adversaries.sol";

contract KeyringMultisigTest is Test {
    LaunchToken private token;
    KeyringMultisig private multisig;
    uint256 private id;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    address private constant DAVE = address(0xDA7E);
    address private constant PAYEE = address(0xBEEF);

    function setUp() public {
        vm.warp(1_000_000);
        vm.deal(address(this), 100 ether);
        token = new LaunchToken();
        multisig = new KeyringMultisig(address(token));
        id = multisig.createWallet(ALICE, BOB, CAROL);
        token.approve(address(multisig), type(uint256).max);
    }

    function test_ConstructorStoresTokenAndHoldsNothing() public view {
        assertEq(address(multisig.token()), address(token));
        assertEq(address(multisig).balance, 0);
        assertEq(token.balanceOf(address(multisig)), 0);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_ConstructorRejectsZeroOrNonContractToken() public {
        vm.expectRevert(KeyringMultisig.InvalidToken.selector);
        new KeyringMultisig(address(0));
        vm.expectRevert(KeyringMultisig.InvalidToken.selector);
        new KeyringMultisig(ALICE);
    }

    function test_AnyoneCreatesSequentialWalletsWithIndexedOwners() public {
        vm.expectEmit(true, true, true, true, address(multisig));
        emit KeyringMultisig.WalletCreated(2, BOB, CAROL, DAVE);
        vm.prank(PAYEE);
        uint256 second = multisig.createWallet(BOB, CAROL, DAVE);
        assertEq(id, 1);
        assertEq(second, 2);
        assertEq(multisig.walletCount(), 2);
        (address[3] memory owners, uint256 ethBalance, uint256 tokenBalance) = multisig.wallet(second);
        assertEq(owners[0], BOB);
        assertEq(owners[1], CAROL);
        assertEq(owners[2], DAVE);
        assertEq(ethBalance, 0);
        assertEq(tokenBalance, 0);
        assertEq(multisig.proposalCount(second), 0);
    }

    function test_RejectsEveryZeroOrDuplicateOwnerPosition() public {
        address[3][6] memory cases = [
            [address(0), BOB, CAROL],
            [ALICE, address(0), CAROL],
            [ALICE, BOB, address(0)],
            [ALICE, ALICE, CAROL],
            [ALICE, BOB, ALICE],
            [ALICE, BOB, BOB]
        ];
        for (uint256 i; i < cases.length; ++i) {
            vm.expectRevert(KeyringMultisig.InvalidOwners.selector);
            multisig.createWallet(cases[i][0], cases[i][1], cases[i][2]);
        }
        assertEq(multisig.walletCount(), 1);
    }

    function test_AnyoneDepositsEthAndKeyrWithEvents() public {
        vm.expectEmit(true, true, false, true, address(multisig));
        emit KeyringMultisig.Deposited(id, address(this), false, 2 ether);
        multisig.depositEth{value: 2 ether}(id);
        vm.expectEmit(true, true, false, true, address(multisig));
        emit KeyringMultisig.Deposited(id, address(this), true, 100e18);
        multisig.depositToken(id, 100e18);
        _assertBalances(id, 2 ether, 100e18);
    }

    function test_UnknownWalletDepositsRevertWithoutMovingAssets() public {
        for (uint256 i; i < 2; ++i) {
            uint256 unknown = i == 0 ? 0 : id + 1;
            vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
            multisig.depositEth{value: 1 ether}(unknown);
            vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
            multisig.depositToken(unknown, 1e18);
        }
        assertEq(address(multisig).balance, 0);
        assertEq(token.balanceOf(address(multisig)), 0);
    }

    function test_ZeroDepositsRevert() public {
        vm.expectRevert(KeyringMultisig.ZeroAmount.selector);
        multisig.depositEth(id);
        vm.expectRevert(KeyringMultisig.ZeroAmount.selector);
        multisig.depositToken(id, 0);
    }

    function test_DepositRequiresAllowanceAndBalance() public {
        token.approve(address(multisig), 0);
        vm.expectRevert();
        multisig.depositToken(id, 1);
        vm.startPrank(DAVE);
        token.approve(address(multisig), 1);
        vm.expectRevert();
        multisig.depositToken(id, 1);
        vm.stopPrank();
        _assertBalances(id, 0, 0);
    }

    function test_PlainEthAndUnknownCalldataRevert() public {
        (bool plain,) = address(multisig).call{value: 1 ether}("");
        (bool fallbackCall,) = address(multisig).call{value: 1 ether}(hex"12345678");
        assertFalse(plain);
        assertFalse(fallbackCall);
        assertEq(address(multisig).balance, 0);
    }

    function test_DirectTokenTransferIsUntrackedAndCannotBeSpent() public {
        token.transfer(address(multisig), 100e18);
        _assertBalances(id, 0, 0);
        uint256 pid = _ready(id, true, PAYEE, 1);
        vm.expectRevert(KeyringMultisig.InsufficientBalance.selector);
        vm.prank(ALICE);
        multisig.execute(id, pid);
        multisig.depositToken(id, 5e18);
        _assertBalances(id, 0, 5e18);
        assertEq(token.balanceOf(address(multisig)), 105e18);
    }

    function test_NonOwnersCannotProposeConfirmRevokeOrExecute() public {
        uint256 pid = _ready(id, false, PAYEE, 1);
        vm.startPrank(DAVE);
        vm.expectRevert(KeyringMultisig.NotOwner.selector);
        multisig.propose(id, false, PAYEE, 1);
        vm.expectRevert(KeyringMultisig.NotOwner.selector);
        multisig.confirm(id, pid);
        vm.expectRevert(KeyringMultisig.NotOwner.selector);
        multisig.revoke(id, pid);
        vm.expectRevert(KeyringMultisig.NotOwner.selector);
        multisig.execute(id, pid);
        vm.stopPrank();
    }

    function test_UnknownWalletActionsAndViewsRevert() public {
        uint256 unknown = 2;
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.propose(unknown, false, PAYEE, 1);
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.confirm(unknown, 1);
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.revoke(unknown, 1);
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.execute(unknown, 1);
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.wallet(unknown);
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.proposalCount(unknown);
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.proposal(unknown, 1);
        vm.expectRevert(KeyringMultisig.UnknownWallet.selector);
        multisig.isConfirmed(unknown, 1, ALICE);
    }

    function test_UnknownProposalActionsAndViewsRevert() public {
        vm.startPrank(ALICE);
        for (uint256 pid; pid < 2; ++pid) {
            vm.expectRevert(KeyringMultisig.UnknownProposal.selector);
            multisig.confirm(id, pid);
            vm.expectRevert(KeyringMultisig.UnknownProposal.selector);
            multisig.revoke(id, pid);
            vm.expectRevert(KeyringMultisig.UnknownProposal.selector);
            multisig.execute(id, pid);
            vm.expectRevert(KeyringMultisig.UnknownProposal.selector);
            multisig.proposal(id, pid);
            vm.expectRevert(KeyringMultisig.UnknownProposal.selector);
            multisig.isConfirmed(id, pid, ALICE);
        }
        vm.stopPrank();
    }

    function test_ProposalsRejectZeroValueAndRecipient() public {
        vm.startPrank(ALICE);
        vm.expectRevert(KeyringMultisig.ZeroAmount.selector);
        multisig.propose(id, false, PAYEE, 0);
        vm.expectRevert(KeyringMultisig.InvalidRecipient.selector);
        multisig.propose(id, true, address(0), 1);
        vm.stopPrank();
        assertEq(multisig.proposalCount(id), 0);
    }

    function test_ProposalRecordsFieldsAutomaticConfirmationAndEvents() public {
        vm.expectEmit(true, true, true, true, address(multisig));
        emit KeyringMultisig.Proposed(id, 1, ALICE, true, PAYEE, 2e18);
        vm.expectEmit(true, true, true, true, address(multisig));
        emit KeyringMultisig.Confirmed(id, 1, ALICE);
        vm.prank(ALICE);
        uint256 pid = multisig.propose(id, true, PAYEE, 2e18);
        KeyringMultisig.Proposal memory p = multisig.proposal(id, pid);
        assertEq(pid, 1);
        assertEq(multisig.proposalCount(id), 1);
        assertTrue(p.isToken);
        assertEq(p.to, PAYEE);
        assertEq(p.value, 2e18);
        assertEq(p.createdAt, block.timestamp);
        assertEq(p.confirmations, 1);
        assertFalse(p.executed);
        assertTrue(multisig.isConfirmed(id, pid, ALICE));
        assertFalse(multisig.isConfirmed(id, pid, BOB));
        assertFalse(multisig.isConfirmed(id, pid, DAVE));
    }

    function test_DuplicateConfirmAndUnconfirmedRevokeRevert() public {
        vm.prank(ALICE);
        uint256 pid = multisig.propose(id, false, PAYEE, 1);
        vm.expectRevert(KeyringMultisig.AlreadyConfirmed.selector);
        vm.prank(ALICE);
        multisig.confirm(id, pid);
        vm.expectRevert(KeyringMultisig.NotConfirmed.selector);
        vm.prank(BOB);
        multisig.revoke(id, pid);
        assertEq(multisig.proposal(id, pid).confirmations, 1);
        vm.expectRevert(KeyringMultisig.InsufficientConfirmations.selector);
        vm.prank(ALICE);
        multisig.execute(id, pid);
    }

    function test_RevocationDropsBelowThresholdAndReconfirmationRestoresIt() public {
        multisig.depositEth{value: 1 ether}(id);
        uint256 pid = _ready(id, false, PAYEE, 1 ether);
        vm.expectEmit(true, true, true, true, address(multisig));
        emit KeyringMultisig.Revoked(id, pid, BOB);
        vm.prank(BOB);
        multisig.revoke(id, pid);
        assertFalse(multisig.isConfirmed(id, pid, BOB));
        assertEq(multisig.proposal(id, pid).confirmations, 1);
        vm.expectRevert(KeyringMultisig.InsufficientConfirmations.selector);
        vm.prank(CAROL);
        multisig.execute(id, pid);
        vm.expectRevert(KeyringMultisig.NotConfirmed.selector);
        vm.prank(BOB);
        multisig.revoke(id, pid);
        vm.expectEmit(true, true, true, true, address(multisig));
        emit KeyringMultisig.Confirmed(id, pid, BOB);
        vm.prank(BOB);
        multisig.confirm(id, pid);
        vm.prank(CAROL);
        multisig.execute(id, pid);
        assertEq(PAYEE.balance, 1 ether);
    }

    function test_AllConfirmationsCanBeRevokedAndThirdOwnerCanConfirm() public {
        uint256 pid = _ready(id, false, PAYEE, 1);
        vm.prank(CAROL);
        multisig.confirm(id, pid);
        assertEq(multisig.proposal(id, pid).confirmations, 3);
        vm.prank(ALICE);
        multisig.revoke(id, pid);
        vm.prank(BOB);
        multisig.revoke(id, pid);
        vm.prank(CAROL);
        multisig.revoke(id, pid);
        assertEq(multisig.proposal(id, pid).confirmations, 0);
    }

    function test_ExecuteEthDebitsOnlyEthAndEmitsEvent() public {
        multisig.depositEth{value: 2 ether}(id);
        multisig.depositToken(id, 30e18);
        uint256 pid = _ready(id, false, PAYEE, 1 ether);
        vm.expectEmit(true, true, true, true, address(multisig));
        emit KeyringMultisig.Executed(id, pid, PAYEE, false, 1 ether);
        vm.prank(CAROL);
        multisig.execute(id, pid);
        assertEq(PAYEE.balance, 1 ether);
        _assertBalances(id, 1 ether, 30e18);
        assertTrue(multisig.proposal(id, pid).executed);
        assertEq(address(multisig).balance, 1 ether);
    }

    function test_ExecuteKeyrDebitsOnlyKeyr() public {
        multisig.depositEth{value: 1 ether}(id);
        multisig.depositToken(id, 30e18);
        uint256 pid = _ready(id, true, PAYEE, 20e18);
        vm.expectEmit(true, true, true, true, address(multisig));
        emit KeyringMultisig.Executed(id, pid, PAYEE, true, 20e18);
        vm.prank(BOB);
        multisig.execute(id, pid);
        assertEq(token.balanceOf(PAYEE), 20e18);
        _assertBalances(id, 1 ether, 10e18);
        assertEq(token.balanceOf(address(multisig)), 10e18);
    }

    function test_ExecutedProposalRejectsExecuteConfirmAndRevoke() public {
        multisig.depositEth{value: 2 ether}(id);
        uint256 pid = _ready(id, false, PAYEE, 1 ether);
        vm.prank(ALICE);
        multisig.execute(id, pid);
        vm.startPrank(CAROL);
        vm.expectRevert(KeyringMultisig.AlreadyExecuted.selector);
        multisig.execute(id, pid);
        vm.expectRevert(KeyringMultisig.AlreadyExecuted.selector);
        multisig.confirm(id, pid);
        vm.expectRevert(KeyringMultisig.AlreadyExecuted.selector);
        multisig.revoke(id, pid);
        vm.stopPrank();
        assertEq(PAYEE.balance, 1 ether);
    }

    function test_ExecutionOneSecondBeforeExpirySucceeds() public {
        multisig.depositEth{value: 1 ether}(id);
        uint256 pid = _ready(id, false, PAYEE, 1 ether);
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(ALICE);
        multisig.execute(id, pid);
        assertTrue(multisig.proposal(id, pid).executed);
    }

    function test_ExecutionAtExpiryReverts() public {
        _assertExpired(0);
    }

    function testFuzz_ExecutionAfterExpiryReverts(uint32 late) public {
        _assertExpired(uint256(late) + 1);
    }

    function test_ExpiryPreventsConfirmationAndRevocationButNewProposalCanSpend() public {
        multisig.depositEth{value: 1 ether}(id);
        uint256 pid = _ready(id, false, PAYEE, 1 ether);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(KeyringMultisig.ProposalExpired.selector);
        vm.prank(CAROL);
        multisig.confirm(id, pid);
        vm.expectRevert(KeyringMultisig.ProposalExpired.selector);
        vm.prank(ALICE);
        multisig.revoke(id, pid);
        uint256 fresh = _ready(id, false, PAYEE, 1 ether);
        assertEq(fresh, 2);
        vm.prank(BOB);
        multisig.execute(id, fresh);
        assertEq(PAYEE.balance, 1 ether);
        assertFalse(multisig.proposal(id, pid).executed);
    }

    function test_EthProposalCannotSpendAnotherWalletOrUseTokenLedger() public {
        uint256 other = multisig.createWallet(ALICE, BOB, DAVE);
        multisig.depositEth{value: 2 ether}(other);
        multisig.depositToken(id, 2e18);
        uint256 pid = _ready(id, false, PAYEE, 1 ether);
        vm.expectRevert(KeyringMultisig.InsufficientBalance.selector);
        vm.prank(ALICE);
        multisig.execute(id, pid);
        _assertBalances(id, 0, 2e18);
        _assertBalances(other, 2 ether, 0);
        assertFalse(multisig.proposal(id, pid).executed);
    }

    function test_KeyrProposalCannotSpendAnotherWalletOrUseEthLedger() public {
        uint256 other = multisig.createWallet(ALICE, BOB, DAVE);
        multisig.depositToken(other, 2e18);
        multisig.depositEth{value: 2 ether}(id);
        uint256 pid = _ready(id, true, PAYEE, 1e18);
        vm.expectRevert(KeyringMultisig.InsufficientBalance.selector);
        vm.prank(ALICE);
        multisig.execute(id, pid);
        _assertBalances(id, 2 ether, 0);
        _assertBalances(other, 0, 2e18);
        assertFalse(multisig.proposal(id, pid).executed);
    }

    function test_ProposalsReserveNothingAndInsufficientBalanceCanBeFundedLater() public {
        uint256 first = _ready(id, false, PAYEE, 1 ether);
        uint256 second = _ready(id, false, PAYEE, 1 ether);
        multisig.depositEth{value: 1 ether}(id);
        vm.prank(ALICE);
        multisig.execute(id, second);
        vm.expectRevert(KeyringMultisig.InsufficientBalance.selector);
        vm.prank(ALICE);
        multisig.execute(id, first);
        multisig.depositEth{value: 1 ether}(id);
        vm.prank(ALICE);
        multisig.execute(id, first);
        assertEq(PAYEE.balance, 2 ether);
        _assertBalances(id, 0, 0);
    }

    function test_ProposalIdsAndConfirmationsAreIsolatedEvenWithSharedOwners() public {
        uint256 other = multisig.createWallet(ALICE, BOB, DAVE);
        multisig.depositEth{value: 1 ether}(id);
        multisig.depositToken(other, 2e18);
        uint256 first = _ready(id, false, PAYEE, 1 ether);
        vm.prank(ALICE);
        uint256 second = multisig.propose(other, true, DAVE, 2e18);
        assertEq(first, 1);
        assertEq(second, 1);
        assertFalse(multisig.isConfirmed(other, second, BOB));
        vm.expectRevert(KeyringMultisig.InsufficientConfirmations.selector);
        vm.prank(ALICE);
        multisig.execute(other, second);
        vm.prank(ALICE);
        multisig.execute(id, first);
        assertFalse(multisig.proposal(other, second).executed);
        vm.expectRevert(KeyringMultisig.NotOwner.selector);
        vm.prank(CAROL);
        multisig.confirm(other, second);
        vm.prank(DAVE);
        multisig.confirm(other, second);
        vm.prank(BOB);
        multisig.execute(other, second);
        assertEq(token.balanceOf(DAVE), 2e18);
    }

    function test_RevertingRecipientRollsBackAndCanRetryBeforeExpiry() public {
        Recipient recipient = new Recipient(multisig);
        multisig.depositEth{value: 2 ether}(id);
        uint256 pid = _ready(id, false, address(recipient), 1 ether);
        recipient.configure(id, pid, pid, true, false, false);
        vm.expectRevert(KeyringMultisig.EthTransferFailed.selector);
        vm.prank(ALICE);
        multisig.execute(id, pid);
        _assertBalances(id, 2 ether, 0);
        assertFalse(multisig.proposal(id, pid).executed);
        assertEq(multisig.proposal(id, pid).confirmations, 2);
        uint256 other = _ready(id, false, PAYEE, 1 ether);
        vm.prank(BOB);
        multisig.execute(id, other);
        recipient.configure(id, pid, pid, false, false, false);
        vm.prank(BOB);
        multisig.execute(id, pid);
        assertEq(address(recipient).balance, 1 ether);
        _assertBalances(id, 0, 0);
    }

    function test_ReentrantOwnerCannotExecuteTwiceAndSeesSettledState() public {
        _assertReentrancy(false, false);
    }

    function test_ReentrantOwnerCannotExecuteAnotherReadyProposal() public {
        _assertReentrancy(true, false);
    }

    function test_BubblingReentrancyFailureRollsBackAndAllowsRetry() public {
        _assertReentrancy(false, true);
    }

    function test_TokenDepositCreditsActualReceivedAmount() public {
        (TestToken asset, KeyringMultisig vault) = _mockVault();
        asset.configure(false, false, false, 1000);
        vm.expectEmit(true, true, false, true, address(vault));
        emit KeyringMultisig.Deposited(1, address(this), true, 90e18);
        vault.depositToken(1, 100e18);
        (,, uint256 credited) = vault.wallet(1);
        assertEq(credited, 90e18);
        assertEq(asset.balanceOf(address(vault)), 90e18);
    }

    function test_FalseReturnDepositAndZeroReceivedRevertAtomically() public {
        (TestToken asset, KeyringMultisig vault) = _mockVault();
        asset.configure(false, true, false, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(asset)));
        vault.depositToken(1, 100);
        asset.configure(false, false, false, 10_000);
        vm.expectRevert(KeyringMultisig.ZeroAmount.selector);
        vault.depositToken(1, 100);
        assertEq(asset.balanceOf(address(this)), 1e27);
        (,, uint256 credited) = vault.wallet(1);
        assertEq(credited, 0);
    }

    function test_OptionalTokenReturnsAreSupportedForDepositAndExecution() public {
        (TestToken asset, KeyringMultisig vault) = _mockVault();
        asset.configure(false, false, true, 0);
        vault.depositToken(1, 100);
        vm.prank(ALICE);
        uint256 pid = vault.propose(1, true, PAYEE, 100);
        vm.prank(BOB);
        vault.confirm(1, pid);
        vm.prank(CAROL);
        vault.execute(1, pid);
        assertEq(asset.balanceOf(PAYEE), 100);
        (,, uint256 credited) = vault.wallet(1);
        assertEq(credited, 0);
    }

    function test_FailedTokenTransferRollsBackAndCanRetry() public {
        (TestToken asset, KeyringMultisig vault) = _mockVault();
        vault.depositToken(1, 100);
        vm.prank(ALICE);
        uint256 pid = vault.propose(1, true, PAYEE, 100);
        vm.prank(BOB);
        vault.confirm(1, pid);
        asset.configure(true, false, false, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(asset)));
        vm.prank(ALICE);
        vault.execute(1, pid);
        (,, uint256 credited) = vault.wallet(1);
        assertEq(credited, 100);
        assertEq(asset.balanceOf(address(vault)), 100);
        assertFalse(vault.proposal(1, pid).executed);
        asset.configure(false, false, false, 0);
        vm.prank(ALICE);
        vault.execute(1, pid);
        assertEq(asset.balanceOf(PAYEE), 100);
    }

    function test_TokenCallbackCannotNestDepositsOrExecute() public {
        (TestToken asset, KeyringMultisig vault) = _mockVault();
        asset.setCallback(address(vault), abi.encodeCall(vault.depositToken, (1, 1)));
        vault.depositToken(1, 100);
        assertFalse(asset.callbackSucceeded());
        assertEq(asset.callbackError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        vm.prank(ALICE);
        uint256 pid = vault.propose(1, true, PAYEE, 100);
        vm.prank(BOB);
        vault.confirm(1, pid);
        asset.setCallback(address(vault), abi.encodeCall(vault.execute, (1, pid)));
        vm.prank(ALICE);
        vault.execute(1, pid);
        assertFalse(asset.callbackSucceeded());
        assertEq(asset.balanceOf(PAYEE), 100);
    }

    function testFuzz_MultipleWalletConservation(uint96 ethAmount, uint96 tokenAmount) public {
        uint256 ethValue = bound(ethAmount, 1, 40 ether);
        uint256 tokenValue = bound(tokenAmount, 1, 1e24);
        uint256 other = multisig.createWallet(ALICE, BOB, DAVE);
        multisig.depositEth{value: ethValue}(id);
        multisig.depositEth{value: ethValue}(other);
        multisig.depositToken(id, tokenValue);
        multisig.depositToken(other, tokenValue);
        token.transfer(address(multisig), 7);
        uint256 ethPid = _ready(id, false, PAYEE, ethValue);
        uint256 tokenPid = _ready(other, true, PAYEE, tokenValue);
        vm.prank(ALICE);
        multisig.execute(id, ethPid);
        vm.prank(BOB);
        multisig.execute(other, tokenPid);
        _assertBalances(id, 0, tokenValue);
        _assertBalances(other, ethValue, 0);
        assertEq(address(multisig).balance, ethValue);
        assertEq(token.balanceOf(address(multisig)), tokenValue + 7);
    }

    function _ready(uint256 walletId, bool isToken, address to, uint256 value) private returns (uint256 pid) {
        vm.prank(ALICE);
        pid = multisig.propose(walletId, isToken, to, value);
        vm.prank(BOB);
        multisig.confirm(walletId, pid);
    }

    function _assertBalances(uint256 walletId, uint256 ethBalance, uint256 tokenBalance) private view {
        (, uint256 actualEth, uint256 actualToken) = multisig.wallet(walletId);
        assertEq(actualEth, ethBalance);
        assertEq(actualToken, tokenBalance);
    }

    function _assertExpired(uint256 late) private {
        multisig.depositEth{value: 1 ether}(id);
        uint256 pid = _ready(id, false, PAYEE, 1 ether);
        vm.warp(block.timestamp + 7 days + late);
        vm.expectRevert(KeyringMultisig.ProposalExpired.selector);
        vm.prank(ALICE);
        multisig.execute(id, pid);
        _assertBalances(id, 1 ether, 0);
        assertFalse(multisig.proposal(id, pid).executed);
    }

    function _assertReentrancy(bool anotherProposal, bool bubble) private {
        Recipient recipient = new Recipient(multisig);
        uint256 attackId = multisig.createWallet(ALICE, BOB, address(recipient));
        multisig.depositEth{value: 3 ether}(attackId);
        uint256 pid = _ready(attackId, false, address(recipient), 1 ether);
        uint256 nestedPid = anotherProposal ? _ready(attackId, false, PAYEE, 1 ether) : pid;
        recipient.configure(attackId, pid, nestedPid, false, true, bubble);
        if (bubble) vm.expectRevert(KeyringMultisig.EthTransferFailed.selector);
        vm.prank(ALICE);
        multisig.execute(attackId, pid);
        if (bubble) {
            assertFalse(multisig.proposal(attackId, pid).executed);
            _assertBalances(attackId, 3 ether, 0);
            recipient.configure(attackId, pid, nestedPid, false, true, false);
            vm.prank(BOB);
            multisig.execute(attackId, pid);
        }
        assertFalse(recipient.nestedSucceeded());
        assertEq(recipient.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertTrue(recipient.observedExecuted());
        assertEq(recipient.observedEthBalance(), 2 ether);
        assertEq(recipient.calls(), 1);
        assertEq(address(recipient).balance, 1 ether);
        assertEq(PAYEE.balance, 0);
        _assertBalances(attackId, 2 ether, 0);
        if (anotherProposal) assertFalse(multisig.proposal(attackId, nestedPid).executed);
    }

    function _mockVault() private returns (TestToken asset, KeyringMultisig vault) {
        asset = new TestToken();
        vault = new KeyringMultisig(address(asset));
        vault.createWallet(ALICE, BOB, CAROL);
        asset.approve(address(vault), type(uint256).max);
    }
}
