# Contract interface

The JSON files in `docs/abi/` are complete Solidity ABIs generated from the pinned
compiler artifacts. Run `forge build` and `python3 scripts/export_abis.py` to
refresh them, or pass `--check` to detect differences without writing files.

## LaunchToken

Constructor: no arguments, nonpayable. Standard ERC-20 functions:
`name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf(address)`,
`allowance(address,address)`, `approve(address,uint256)`,
`transfer(address,uint256)`, `transferFrom(address,address,uint256)`.
Amounts are base units (18 decimals). Transfer/approval functions return `bool`
and emit standard ERC-20 events; errors are the OpenZeppelin IERC6093 errors in
the exported ABI. Infinite allowance remains unchanged on `transferFrom`.

## KeyringMultisig

Constructor: one `address token_`, nonpayable. No initializer.

| Function | Returns / behavior |
| --- | --- |
| `token()` | Immutable KEYR address |
| `PROPOSAL_LIFETIME()` | `604800` seconds |
| `walletCount()` | Highest allocated wallet ID, initially zero |
| `createWallet(address,address,address)` | New `uint256 id`; starts at 1 |
| `wallet(uint256 id)` | `(address[3] owners, uint256 ethBalance, uint256 tokenBalance)` |
| `depositEth(uint256 id)` | Payable; positive `msg.value`, existing wallet |
| `depositToken(uint256 id,uint256 amount)` | Nonpayable; positive amount, approve beforehand |
| `proposalCount(uint256 id)` | Highest proposal ID in this wallet, initially zero |
| `propose(uint256 id,bool isToken,address to,uint256 value)` | New `uint256 pid`; automatically confirms proposer |
| `proposal(uint256 id,uint256 pid)` | One tuple: `(bool isToken,address to,uint256 value,uint256 createdAt,uint8 confirmations,bool executed)` |
| `isConfirmed(uint256 id,uint256 pid,address owner)` | Current boolean flag; false for any nonowner |
| `confirm(uint256 id,uint256 pid)` | Record one owner confirmation |
| `revoke(uint256 id,uint256 pid)` | Remove the caller's confirmation |
| `execute(uint256 id,uint256 pid)` | Send selected asset after threshold/balance/expiry checks |

All wallet-specific views revert for unknown wallets. Proposal views and actions
revert for nonexistent proposal IDs, including zero. `proposal()` and
`isConfirmed()` remain readable after execution or expiry. Expiry is derived from
`createdAt + PROPOSAL_LIFETIME()`; there is no separate stored expired flag. An
expired proposal's confirmation count may still be two or three, but it is not
executable. Use a `(walletId, proposalId)` pair as the frontend key.

## Events

| Event | Indexed fields | Non-indexed fields |
| --- | --- | --- |
| `WalletCreated` | `owner1`, `owner2`, `owner3` | `id` |
| `Deposited` | `id`, `from` | `isToken`, `amount` (actual received) |
| `Proposed` | `id`, `pid`, `proposer` | `isToken`, `to`, `value` |
| `Confirmed` | `id`, `pid`, `owner` | none |
| `Revoked` | `id`, `pid`, `owner` | none |
| `Executed` | `id`, `pid`, `to` | `isToken`, `value` |

Query `WalletCreated` separately for each indexed owner position and merge by ID;
an RPC filter across different topic positions applies AND, not OR. Proposals can
be enumerated from 1 through `proposalCount(id)` or discovered with `Proposed`.
Read views for current balances and confirmation state. Do not treat event order
inside recipient callbacks as a substitute for reading current state. Wait for
transaction confirmation and account for chain reorganizations when caching logs.

## Errors and integration behavior

`InvalidToken`, `InvalidOwners`, `UnknownWallet`, `UnknownProposal`, `NotOwner`,
`InvalidRecipient`, `ZeroAmount`, `AlreadyConfirmed`, `NotConfirmed`,
`AlreadyExecuted`, `ProposalExpired`, `InsufficientConfirmations`,
`InsufficientBalance`, and `EthTransferFailed` are zero-argument custom errors.
SafeERC20, Address, and ReentrancyGuard errors are included in the ABI; underlying
token errors may also bubble through. A revert leaves proposal and ledger state
unchanged. Owners can retry a failed transfer before expiry or create a fresh
proposal. Gas estimation/execution can fail if another transaction spends funds,
revokes a confirmation, or reaches the expiry boundary first.

Only `depositEth` is payable. Sending ETH via plain transfer or to a nonpayable
function reverts. ERC-20 approval targets the **multisig contract address**, and
the following `depositToken` transaction targets the intended wallet ID.
