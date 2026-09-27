# Independent review handoff

This is an implementation evidence map, not an independent review or release
approval. Review the accepted compiler artifacts, source, ABI, and the separately
generated `launch.json`. No reviewer findings are preemptively waived by these tests.

| Required attack | Local evidence |
| --- | --- |
| Wallet A spending wallet B's ETH | `test_EthProposalCannotSpendAnotherWalletOrUseTokenLedger`; stateful per-wallet liability model |
| Wallet A spending wallet B's KEYR | `test_KeyrProposalCannotSpendAnotherWalletOrUseEthLedger`; stateful model |
| Crossing ETH and KEYR ledgers | The above tests fund the other asset in the attacked wallet; successful asset-specific payout tests |
| Double execution through recipient reentrancy | Reentrant recipient is itself a wallet owner; same and different live proposal attacks, settled-state observations, bubbled-revert retry |
| Revoked or duplicate confirmations counting | Duplicate rejection, revoke below threshold, all confirmations revoked, re-confirmation, independent confirmation-bitset model |
| Proposal ID reuse across wallets | Two overlapping owner groups both use proposal 1, with different assets/recipients; confirmation and execution isolation |

Also inspect:

- The factory remains the holder of all `10^27` token units after both constructors.
  The application constructor has one argument, `$token`, no initializer, and no
  deployer/admin authority. There is exactly one application contract.
- Authorization applies to every proposal mutation and to execution; any owner
  can execute, even one who did not confirm. Creation/deposits are intentionally public.
- Execution debits before transfer and rolls back on failure. Guarded deposits
  prevent callback-driven overlap in balance-delta measurements.
- Expiry is exclusive: actions at exactly `createdAt + 7 days` fail. New proposals
  can spend the same unreserved funds; failed recipients cannot lock a queue.
- No receive/fallback or rescue/sweep path exists. Direct KEYR and forced ETH are
  untracked and unrecoverable; unconditional ETH equality cannot hold against
  forced transfers. Supported-flow ETH equality and KEYR surplus are tested.
- Wallet owners are immutable. Two compromised owners can spend their wallet;
  two unavailable owners lock it. Contract owners may execute arbitrary callbacks.
- The manifest must point to this fixed-supply token. Constructor code-presence
  validation cannot authenticate ERC-20 behavior, supply, or token identity.
- Solidity 0.8.26 / Cancun / optimizer 200 / metadata hash disabled must match
  accepted bytecode. Runtime compatibility tests scan all non-PUSH opcodes and
  enforce the EIP-170 size limit for both deployed contracts.

Concrete source, constructor, policy, or authorization conflicts remain findings.
Source publication, signed-artifact linkage, attestation, admission, deployment,
and final service policy enforcement belong to the services after this stage.
The independent reviewer must assess both accepted source and manifest before release.
