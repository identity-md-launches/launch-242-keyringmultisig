# Keyring contracts

Keyring is a fixed-supply ERC-20 (KEYR) and a native ETH / KEYR 2-of-3 multisig
for **Sepolia, chain ID 11155111**. `KeyringMultisig` stores many wallets by ID
inside one contract; creating a wallet deploys no new contracts.

This deliverable contains the contracts, tests, vendored dependencies, ABI exports,
and the source-stage deployment handoff. A separate assignment produces
`launch.json`, followed by independent adversarial review. Services publish source,
link signed artifacts and policy, attest, admit, and deploy through ProjectFactory.
The one-page website is built against that live deployment afterward. No deployment
or independent audit is claimed by this repository.

## Build and verify

Install Foundry and Solidity **0.8.26** in the execution environment, then run:

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

The configuration pins Solidity 0.8.26, Cancun, optimizer runs 200, and
`bytecode_hash = "none"`. All dependency source is included as ordinary files under
`lib/`; no dependency installation or network is required to build when the pinned
compiler is available. There are no submodules, FFI settings, filesystem cheatcode
permissions, private keys, broadcast scripts, or environment-dependent tests.
Dependencies are OpenZeppelin Contracts v5.0.2 (the required source subset, MIT)
and forge-std v1.9.7 (source, MIT/Apache-2.0); licenses are vendored alongside them.
[`lib/dependencies.json`](lib/dependencies.json) records upstream tags and archive hashes.

To regenerate the ABI exports after a source change:

```sh
forge build
python3 scripts/export_abis.py
```

## Contracts and deployment parameters

| Artifact | Source | Nonpayable constructor | Initial state |
| --- | --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | `[]` | All `10^27` base units minted to `msg.sender` |
| `KeyringMultisig` | `src/KeyringMultisig.sol` | `[address token_]`, manifest reference `["$token"]` | No wallets, ETH, or tokens |

The token is named **Keyring**, symbol **KEYR**, with 18 decimals and exactly
1,000,000,000 tokens. It has standard ERC-20 transfer and allowance operations,
with no external mint/burn, fee, ownership, pause, blocklist, or upgrade functions.
The factory is the constructor caller and receives the entire supply; application
construction neither takes nor needs any of it. The application stores the token
address immutably and rejects zero addresses or addresses without code. It does
not attest token identity: the manifest and reviewers must ensure this address is
the accepted `LaunchToken` artifact. No initializer or postdeployment setup is needed.

The manifest contribution should use kind `evm_project`, name `LaunchToken` as the
launch token, and include exactly one application, `KeyringMultisig`, whose only
argument is `$token`. There is no owner argument or privileged deployment wallet.
Both contracts are ordinary, non-upgradeable deployments; the application uses no
contract creation, delegatecall, callcode, or selfdestruct.

The deployment service supplies the canonical factory, owner/policy context,
signed artifact links, reward allocation, and actual addresses. It must verify
Sepolia, constructor linkage, compiler settings, and accepted bytecode. Pool settings
from the approved launch guidance are native ETH as the paired asset, fee 3000,
tick spacing 60, and legacy `initialPrice` `79228162514264337593543950336`.
The service derives effective opening price and allocations from pinned policy;
these are not constructor parameters. Users obtain KEYR by swapping Sepolia ETH
in the launch pool. The application does not start funded and does not perform swaps.

## Wallet lifecycle

1. Anyone calls `createWallet(owner1, owner2, owner3)`. Owners must be distinct and
   nonzero; the creator need not be an owner. IDs start at 1. Owners are immutable
   and can be EOAs or contracts. There is no wallet deletion or owner rotation.
2. Anyone can fund an existing wallet using `depositEth(id)` with positive ETH,
   or by approving the multisig for KEYR and calling `depositToken(id, amount)`
   with a positive amount. The token ledger credits the actual balance increase.
   Zero received tokens, insufficient approval, and unknown wallet IDs revert.
3. An owner calls `propose(id, isToken, to, value)`. `to` must be nonzero and `value`
   positive. `false` selects wei of ETH; `true` selects base units of KEYR.
   There is no arbitrary calldata. Proposal IDs start at 1 **within each wallet**.
   Creation automatically confirms for the proposer and emits both `Proposed`
   and `Confirmed`. Proposals may exceed current balances and reserve nothing.
4. Other owners may `confirm`; any confirmed owner, including the proposer, may
   `revoke`. Duplicate confirmations and revoking an absent confirmation revert.
   Current confirmations can range from zero to three.
5. Any of that wallet's owners, including one who has not confirmed, may `execute`
   once at least two owners currently confirm and that wallet has sufficient funds
   in the selected asset. Execution marks the proposal executed and debits that
   asset's wallet ledger before transferring. The global reentrancy guard covers
   execution and both deposit methods. Transfers use ETH `call` or SafeERC20.
6. ETH rejection or a failed token transfer reverts the entire execution, including
   its debit, executed flag, and event. It can be retried while live; another proposal
   can pay a different recipient. No failed recipient can block unrelated proposals.

Confirm, revoke, and execute require `block.timestamp < createdAt + 7 days`.
They all revert **at** the deadline and afterward. Executed proposals cannot be
confirmed, revoked, or executed again. Expired proposals remain readable, with
their historical confirmations, but cannot move funds. No cleanup, keeper, or
refund call is necessary because proposals lock no funds: any two owners can
authorize a fresh payout. Deposits have no individual refund right; funds belong
to the wallet and require its threshold authorization to leave.

## Accounting and custody assumptions

Each wallet has separate ETH and KEYR balances. Confirmations and proposal IDs
are keyed by both wallet ID and proposal ID. A wallet cannot use another wallet's
balance, the other asset's ledger, or untracked surplus. Only the fixed KEYR token
is intended for deployment; SafeERC20 and balance-delta deposits do not make this
a generic vault safe for arbitrary rebasing or malicious tokens.

**Plain ETH transfers revert. KEYR transferred directly to the multisig without
`depositToken` is untracked and unrecoverable.** There is no rescue or sweep role.
Approving tokens alone does not deposit them. A proposal sending KEYR back to the
multisig itself also turns its debited value into untracked surplus; owners should
review destinations. An ETH proposal to the multisig itself reverts.

For the supported deposit/execution flows, the contract's ETH equals the sum of
wallet ETH balances. Its KEYR balance is at least the sum of wallet token balances;
the difference consists of direct token donations. At the EVM level, ETH can be
forced into an address without calling it, so unconditional ETH equality is
impossible. Forced ETH is untracked and unrecoverable; in that case the contract's
ETH is greater than its total wallet liabilities. The invariant suite tests exact
ETH equality under normal flows, plus token donation surplus and an independent
model of every wallet's liabilities, payouts, proposal fields, and confirmations.

There is no contract-wide administrator, emergency pause, recovery key, or upgrade
path. Any two owners can spend all of their wallet's assets; losing access to two
owners permanently locks them. The deployer has no special powers. Anyone can list
addresses as owners, so a `WalletCreated` event is not proof those addresses endorsed
the wallet. Users must check all three owners, the wallet ID, asset, amount, recipient,
and expiry before depositing or confirming. Reviewers must consider owner-contract
callbacks and timestamp boundaries. There are no signatures, external oracles,
randomness, external keepers, or off-chain authorization dependencies.

## Validation and operational handoff

The unit/fuzz suites cover ERC-20 supply and approvals, invalid owners and IDs,
deposit validation and balance deltas, owner authorization, duplicate/revoked
confirmations, expiry boundaries, ETH/KEYR ledger separation, wallet and proposal
isolation, unreserved funds, transfer failure and retry, optional/false ERC-20
returns, and reentrant recipients/token callbacks. Stateful tests run 128 sequences
of up to 64 actions using three overlapping owner groups and separate accounting
and confirmation models. Factory compatibility tests check construction without
initialization, untouched factory token supply, nonpayable constructors, runtime
size, and forbidden opcodes.

[`docs/REVIEW_HANDOFF.md`](docs/REVIEW_HANDOFF.md) maps the required independent
attacks to local evidence. Passing these tests is not an independent security audit.
Before release, the review assignment must inspect the accepted source **and**
the separate manifest for concrete constructor, authorization, source, or policy
conflicts. Service publication/attestation/admission outcomes are subsequent work,
not prerequisites to this source contribution.

The frontend assignment uses the live Sepolia deployment and the exported
[`LaunchToken`](docs/abi/LaunchToken.json) and
[`KeyringMultisig`](docs/abi/KeyringMultisig.json) ABIs; interface notes are in
[`docs/ABI.md`](docs/ABI.md). Its single page must list the connected account's
wallets from the three indexed owner positions in `WalletCreated`, deduplicate IDs,
read current contract views, and expose create, deposit, propose, confirm, revoke,
and execute. It reads KEYR through `token()`, shows the connected wallet's KEYR
balance and allowance, and has an approval step before deposits. Explain pool-based
KEYR acquisition without an in-page swap. There is no backend or indexer; export
`dist/index.html` with site label `lab-multisig-factory`. Deployment services provide
addresses and deployment blocks for event queries. Static publication to GitHub
and IPFS follows deployment and review.
