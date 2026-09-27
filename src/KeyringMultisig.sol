// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Many immutable 2-of-3 wallets with isolated ETH and KEYR accounting.
/// @dev No wallet contracts are deployed. Proposals never reserve funds.
contract KeyringMultisig is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PROPOSAL_LIFETIME = 7 days;
    IERC20 public immutable token;
    uint256 public walletCount;

    struct Wallet {
        address[3] owners;
        uint256 ethBalance;
        uint256 tokenBalance;
        uint256 proposalCount;
    }

    struct Proposal {
        bool isToken;
        address to;
        uint256 value;
        uint256 createdAt;
        uint8 confirmations;
        bool executed;
    }

    mapping(uint256 id => Wallet) private _wallets;
    mapping(uint256 id => mapping(uint256 pid => Proposal)) private _proposals;
    mapping(uint256 id => mapping(uint256 pid => mapping(address owner => bool))) private _confirmed;

    error InvalidToken();
    error InvalidOwners();
    error UnknownWallet();
    error UnknownProposal();
    error NotOwner();
    error InvalidRecipient();
    error ZeroAmount();
    error AlreadyConfirmed();
    error NotConfirmed();
    error AlreadyExecuted();
    error ProposalExpired();
    error InsufficientConfirmations();
    error InsufficientBalance();
    error EthTransferFailed();

    event WalletCreated(uint256 id, address indexed owner1, address indexed owner2, address indexed owner3);
    event Deposited(uint256 indexed id, address indexed from, bool isToken, uint256 amount);
    event Proposed(
        uint256 indexed id, uint256 indexed pid, address indexed proposer, bool isToken, address to, uint256 value
    );
    event Confirmed(uint256 indexed id, uint256 indexed pid, address indexed owner);
    event Revoked(uint256 indexed id, uint256 indexed pid, address indexed owner);
    event Executed(uint256 indexed id, uint256 indexed pid, address indexed to, bool isToken, uint256 value);

    /// @param token_ The previously deployed KEYR launch token ($token in the manifest).
    /// @dev Nonpayable, with no token movement or privileged deployer role.
    constructor(address token_) {
        if (token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    modifier onlyWalletOwner(uint256 id) {
        Wallet storage w = _existingWallet(id);
        if (msg.sender != w.owners[0] && msg.sender != w.owners[1] && msg.sender != w.owners[2]) {
            revert NotOwner();
        }
        _;
    }

    /// @notice Anyone may create a wallet; its three owners can never be changed.
    function createWallet(address owner1, address owner2, address owner3) external returns (uint256 id) {
        if (
            owner1 == address(0) || owner2 == address(0) || owner3 == address(0) || owner1 == owner2 || owner1 == owner3
                || owner2 == owner3
        ) revert InvalidOwners();
        id = ++walletCount;
        _wallets[id].owners = [owner1, owner2, owner3];
        emit WalletCreated(id, owner1, owner2, owner3);
    }

    function depositEth(uint256 id) external payable nonReentrant {
        Wallet storage w = _existingWallet(id);
        if (msg.value == 0) revert ZeroAmount();
        w.ethBalance += msg.value;
        emit Deposited(id, msg.sender, false, msg.value);
    }

    /// @notice Requires approval. Credits only the increase in the contract's token balance.
    function depositToken(uint256 id, uint256 amount) external nonReentrant {
        Wallet storage w = _existingWallet(id);
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert ZeroAmount();
        w.tokenBalance += received;
        emit Deposited(id, msg.sender, true, received);
    }

    /// @notice Creates a proposal and records the proposer's first confirmation.
    function propose(uint256 id, bool isToken, address to, uint256 value)
        external
        onlyWalletOwner(id)
        returns (uint256 pid)
    {
        if (to == address(0)) revert InvalidRecipient();
        if (value == 0) revert ZeroAmount();
        pid = ++_wallets[id].proposalCount;
        _proposals[id][pid] = Proposal(isToken, to, value, block.timestamp, 1, false);
        _confirmed[id][pid][msg.sender] = true;
        emit Proposed(id, pid, msg.sender, isToken, to, value);
        emit Confirmed(id, pid, msg.sender);
    }

    function confirm(uint256 id, uint256 pid) external onlyWalletOwner(id) {
        Proposal storage p = _activeProposal(id, pid);
        if (_confirmed[id][pid][msg.sender]) revert AlreadyConfirmed();
        _confirmed[id][pid][msg.sender] = true;
        ++p.confirmations;
        emit Confirmed(id, pid, msg.sender);
    }

    function revoke(uint256 id, uint256 pid) external onlyWalletOwner(id) {
        Proposal storage p = _activeProposal(id, pid);
        if (!_confirmed[id][pid][msg.sender]) revert NotConfirmed();
        _confirmed[id][pid][msg.sender] = false;
        --p.confirmations;
        emit Revoked(id, pid, msg.sender);
    }

    /// @notice Any wallet owner may execute a live proposal with at least two current confirmations.
    /// @dev A failed transfer rolls back both the debit and the executed flag, allowing retry.
    function execute(uint256 id, uint256 pid) external nonReentrant onlyWalletOwner(id) {
        Proposal storage p = _activeProposal(id, pid);
        if (p.confirmations < 2) revert InsufficientConfirmations();
        Wallet storage w = _wallets[id];
        p.executed = true;
        if (p.isToken) {
            if (p.value > w.tokenBalance) revert InsufficientBalance();
            w.tokenBalance -= p.value;
            token.safeTransfer(p.to, p.value);
        } else {
            if (p.value > w.ethBalance) revert InsufficientBalance();
            w.ethBalance -= p.value;
            (bool sent,) = p.to.call{value: p.value}("");
            if (!sent) revert EthTransferFailed();
        }
        emit Executed(id, pid, p.to, p.isToken, p.value);
    }

    function wallet(uint256 id)
        external
        view
        returns (address[3] memory owners, uint256 ethBalance, uint256 tokenBalance)
    {
        Wallet storage w = _existingWallet(id);
        return (w.owners, w.ethBalance, w.tokenBalance);
    }

    function proposalCount(uint256 id) external view returns (uint256) {
        return _existingWallet(id).proposalCount;
    }

    function proposal(uint256 id, uint256 pid) external view returns (Proposal memory) {
        _existingWallet(id);
        return _existingProposal(id, pid);
    }

    function isConfirmed(uint256 id, uint256 pid, address owner) external view returns (bool) {
        _existingWallet(id);
        _existingProposal(id, pid);
        return _confirmed[id][pid][owner];
    }

    function _existingWallet(uint256 id) private view returns (Wallet storage w) {
        w = _wallets[id];
        if (w.owners[0] == address(0)) revert UnknownWallet();
    }

    function _existingProposal(uint256 id, uint256 pid) private view returns (Proposal storage p) {
        if (pid == 0 || pid > _wallets[id].proposalCount) revert UnknownProposal();
        p = _proposals[id][pid];
    }

    function _activeProposal(uint256 id, uint256 pid) private view returns (Proposal storage p) {
        p = _existingProposal(id, pid);
        if (p.executed) revert AlreadyExecuted();
        if (block.timestamp >= p.createdAt + PROPOSAL_LIFETIME) revert ProposalExpired();
    }
}
