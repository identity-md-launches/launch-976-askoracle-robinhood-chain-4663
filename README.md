# AskOracle

One application contract for Robinhood Chain (4663). Anyone approves the existing IMD token to AskOracle and calls `ask(string)`. The contract purchases a yes/no answer through IdentityMD Intake. No token is deployed.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun EVM, optimizer 200 runs, `bytecode_hash = "none"`. Foundry must provide the pinned compiler. All Solidity dependencies are ordinary files under `lib/`: OpenZeppelin Contracts **v5.5.0** (only the dependency closure) and forge-std **v1.9.7**. Versions, source archive hashes and licenses are included. Builds and tests need no network, environment variables, FFI or filesystem permissions. Tests use local mocks; no RPC or funded wallet is used.

`src/OracleAttestation.sol` was copied in full from the supplied canonical protocol reference. It preserves all 15 fields, their order, the exact type string, and the EIP-712 domain **IdentityMD Oracle / 2 / block.chainid / address(this)**. The conformance suite retains the protocol's vector constants and verifies its exact digest and signature. A test-only subclass exposes the verifier for the vector's bytes32-array answer; a separately signed bool tests the application's actual callback through the mock Intake.

## Deployment parameters

`launch.json` specifies one nonpayable constructor, in this order:

| Argument | Initial value |
| --- | --- |
| `owner_` | `$owner`, resolved by the launch service |
| `intake_` | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` |
| `imd_` | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| `action_` | `bytes32("oracle.request@oracle-1")`, right padded UTF-8, **not a hash** |
| `signer_` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| `panelSize_` | `50` |
| `quorum_` | `40` |
| `validForSeconds_` | `86400` |

Addresses are the requester's supplied deployment parameters, not independently verified live deployments. The deployer must confirm chain 4663, dependency code, IMD identity and Intake's action quote before launch. Construction does not call dependencies and assigns ownership to the explicit argument, so deployment through a factory works. There is no initializer, proxy, linked library deployment or native-coin payment path.

## Asking and reading

1. Read `intake()`, `imd()` and `action()`, then `Intake.priceOf(action, imd)`. The supplied launch price is **500000000000000000 units (0.5 IMD at 18 decimals)**. The live quote is authoritative; the contract does not hardcode a price or impose a separate owner price override. Approving exactly the quote limits the caller's exposure if the quote increases before execution.
2. Approve AskOracle for that amount on IMD, then call `ask(question)`. It returns an ID starting at **1**. `Asked` includes that ID, the caller, Intake's request ID, the question and the price paid.
3. Read `question(id)`, returning `(asker, text, status, answer, agreed, quorum, panelSize, askedAt, answeredAt)`. Status is `Pending = 0`, `Answered = 1`, `Unanswered = 2`. Only an Answered record has a meaningful boolean answer: `false` is a successful **no** result. Other result fields are zero before an answer. Invalid local IDs revert.
4. `count()` returns the number of purchased questions. `latestAnswered()` returns the ID of the most recently delivered answer, or **0** if none; it follows delivery order rather than highest question ID. `requestDetails(id)` returns the originating Intake, its request ID and the requested panel/quorum/validity. `questionIdFor(intake, requestId)` maps the pair back to the local ID.

Questions must contain **1–500 UTF-8 bytes**, not characters. Malformed UTF-8, overlong encodings, surrogate code points and Unicode C0/C1 controls (including DEL, newline and tab) revert before payment. Quotes and backslashes are escaped only in JSON; the stored and decoded question is unchanged. The initial body is exactly:

```json
{"v":1,"question":"<JSON-escaped user question>","chainId":4663,"window":{"hours":1},"answerType":"bool","evidence":"panel","panelSize":50,"quorum":40,"validForSeconds":86400}
```

The chain, one-hour relative window, bool type and panel evidence remain fixed. The final three numeric settings follow owner configuration. Text is public and remains user-authored: the requested exact body does not add instructions, definitions or an ambiguity override. Oracle screening and panel interpretation are operational responsibilities. An ambiguous or refused question can still spend its fee and receive no callback.

## Settlement and timeouts

AskOracle pulls exactly the current quote, checks its received balance, approves only that amount, calls Intake, clears the allowance and verifies its balance returns to its pre-call value. A failure rolls back the payment and local record. Fee-on-transfer or rebasing behavior that changes this balance invariant is unsupported. Normal requests leave no funds or token allowance behind. There is no refund, withdrawal, sweep, pause or privileged settlement function. Direct token donations or forcibly sent ETH cannot be prevented and have no recovery path; users should only pay through `ask`.

Only the Intake that accepted a particular request may deliver it. Intake rotation preserves this authority for its existing requests; new requests use the new Intake. Both the local request state and the oracle UUID prevent replay. The callback's first argument is the Intake ID; `a.requestId` is a distinct oracle UUID, consumed globally once. They are intentionally not compared for equality.

The canonical verifier checks the signature and expiration, including its five-minute future issuance tolerance. The application additionally requires chain 4663, a canonical 32-byte bool, at least the panel and quorum requested, `quorum <= agreed <= panelSize <= 300`, an ordered block window, issuance no earlier than the ask, an ordered validity interval, and a signed lifetime no longer than the requested validity. Panel, quorum and validity are saved per question. The current signer applies to all callbacks, including pending questions.

The writer is trusted to pair the Intake ID with the oracle UUID. With a relative window, the resolved `questionHash` cannot be computed at ask time. The signature proves the oracle signed for this consumer; it does not independently prove the writer's pairing or the truth of an off-chain fact. The contract stores the result and emits `Answered`, without executing user actions.

At **`askedAt + 86400`**, callbacks are rejected and **anyone** may call `markUnanswered(id)`. One second before that boundary a valid answer is still accepted. Marking Unanswered is permanent, leaves `answeredAt` zero, preserves the question history, and does not return the fee. The timeout is always 24 hours even if the signed-answer validity setting changes. Time uses `block.timestamp`.

The tests invoke the real callback selector with a **200,000 gas** limit. A cold first EOA-signed callback measured **105,849 gas including CALL overhead** with this compiler configuration. A future ERC-1271 signer has its own execution cost and must be checked against that limit before configuration. Intake callback failures are not retried by the supplied protocol.

## Owner settings and after launch

The owner's address is immutable. The truncated owner sentence in the brief is interpreted using its oracle reference: protocol endpoints/payment asset/action, signer and panel policy may be updated. There is no cross-chain delivery endpoint because this application only uses same-chain Intake callbacks.

| Owner-only call | Responsibility |
| --- | --- |
| `setProtocol(intake, imd, action)` | Set the endpoint, payment token and action together using verified IdentityMD deployment/version information. Nonzero values are required. Each ask reads price from this endpoint. |
| `setSigner(signer)` | Rotate to IdentityMD's verified attester or compatible ERC-1271 registry; zero is rejected. Coordinate pending deliveries because old signatures cease to verify. |
| `setPanel(panelSize, quorum, validForSeconds)` | Choose 2–300 seats, quorum 2–panelSize, and validity 60 seconds–30 days. Affects future questions. |

Every setting emits an event. All initial settings are supplied by the constructor; no post-deployment setup transaction is needed. The owner must monitor protocol upgrades and signer rotation. Changes to the protocol's JSON or attestation schema may require a new application deployment even though endpoint and action addresses are configurable. Users trust owner-selected payment and oracle dependencies; a malicious or broken setting can prevent purchases or answers, and a malicious signer can attest to false answers.

Operators should monitor Asked/Answered/Unanswered events, oracle refusals and callback failures, and arrange permissionless timeout calls. Users bear the spent fee if the panel disagrees, the question is refused, the writer fails, or an answer cannot be delivered before the deadline. The launch service is responsible for deployment and explorer verification. No deployment or transaction broadcast is performed by this project.

Tests cover protocol conformance, payments and rollback, text validation/escaping, both answers, replay, unauthorized callbacks, malformed/tampered/expired attestations, panel constraints, domain separation, configuration changes, timeout boundaries, reentrancy, gas and application opcode/size limits. Fuzzing checks ASCII control rejection and fee conservation. This local validation is not an independent security audit; independent adversarial review remains a release responsibility.
