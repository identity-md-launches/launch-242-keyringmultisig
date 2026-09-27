// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {KeyringMultisig} from "../../src/KeyringMultisig.sol";

contract Recipient {
    KeyringMultisig public immutable multisig;
    bool public reject;
    bool public attack;
    bool public bubbleFailure;
    bool public nestedSucceeded;
    bool public observedExecuted;
    uint256 public observedEthBalance;
    uint256 public calls;
    uint256 public walletId;
    uint256 public proposalId;
    uint256 public nestedProposalId;
    bytes public nestedError;

    constructor(KeyringMultisig multisig_) {
        multisig = multisig_;
    }

    function configure(uint256 id, uint256 pid, uint256 nestedPid, bool reject_, bool attack_, bool bubble_) external {
        walletId = id;
        proposalId = pid;
        nestedProposalId = nestedPid;
        reject = reject_;
        attack = attack_;
        bubbleFailure = bubble_;
    }

    receive() external payable {
        require(!reject, "recipient rejected ETH");
        ++calls;
        if (attack) {
            observedExecuted = multisig.proposal(walletId, proposalId).executed;
            (, observedEthBalance,) = multisig.wallet(walletId);
            (nestedSucceeded, nestedError) =
                address(multisig).call(abi.encodeCall(multisig.execute, (walletId, nestedProposalId)));
            require(!bubbleFailure || nestedSucceeded, "nested execution failed");
        }
    }
}

/// @dev Exercises SafeERC20 failures, optional returns, balance deltas, and callbacks.
contract TestToken is ERC20 {
    bool public failTransfer;
    bool public failTransferFrom;
    bool public noReturn;
    uint256 public feeBps;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackError;

    constructor() ERC20("Test asset", "TEST") {
        _mint(msg.sender, 1e27);
    }

    function configure(bool failOut, bool failIn, bool emptyReturn, uint256 fee) external {
        failTransfer = failOut;
        failTransferFrom = failIn;
        noReturn = emptyReturn;
        feeBps = fee;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfer) return false;
        super.transfer(to, value);
        _callback();
        if (noReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failTransferFrom) return false;
        super.transferFrom(from, to, value);
        _callback();
        if (noReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _callback() private {
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackError) = callbackTarget.call(callbackData);
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
