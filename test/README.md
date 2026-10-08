# AskOracle tests

Run from the repository root:

```sh
forge build
forge test
```

The suite runs offline with the existing vendored dependencies. It neither reads RPC credentials nor changes environment variables.

| File | Coverage |
| --- | --- |
| `AskOracle.t.sol` | Existing request/payment checks, escaping, invalid input, authorization, replay, signature/domain validation, timeouts, rotation, reentrancy, and callback gas. |
| `OracleConsumerConformance.t.sol` | Existing protocol digest and signature vector, canonical callback selector, and a bool delivery signed by the vector key. The unmodified vector uses a different answer type and is verified through a test-only exposure of the inherited verifier. |
| `AskOracleEdges.t.sol` | Tampering with each of the 15 signed fields, bool payload lengths, UTF-8 scalar and byte-length boundaries, JSON injection, ERC-1271 approval/rejection, quote failures, and exact full-balance payments including one wei and maximum uint256. Panel and price properties each run 1,000 fuzz cases. |
| `AskOracleInvariant.t.sol` | Three users, two token/Intake routes, and 256 sequences of 64 randomized actions. Configuration is inline; no Foundry configuration changes are needed. |

The invariant handler tracks successful asks, fees per token and user, donations, request policies, terminal states, signed UUIDs, and the last delivered answer independently of the application's getters. After every random action it checks:

- Users pay exactly the prices quoted for their successful requests. Refused payments roll back and timeouts never refund spent fees.
- Fee recipients receive the accumulated fees; the application retains only unsolicited donations and no approvals to either Intake.
- Every successful ask has one consecutive ID and keeps its original asker, text, Intake ID, time, and requested policy across configuration changes.
- Answered and Unanswered records never reopen. Only answered UUIDs are consumed, results and counts match the operation history, and `latestAnswered` follows delivery order.
- Only owner calls change configuration. Expected failures are checked explicitly; unexpected handler reverts fail the campaign.

A deterministic handler test reaches success, replay rejection, both terminal states, protocol/signer rotation, failed payments and unauthorized setters. Callback success paths run through the mock Intake's 200,000-gas call; added gas tests also cool the consumer and signer before delivery.

The mocks model exact IMD transfers, forwarding, token failure modes, recorded request bodies and the callback stipend. `MockIntake.deliver` deliberately bubbles callback reverts so individual rejection paths can be inspected repeatedly. The live Intake records delivery failure without retrying; the suite's repeated deliveries test consumer defenses, not a promise that production delivery retries exist.

No live Robinhood Chain fork was run. Deployed Intake/IMD code and actual price lookup, forwarding and writer delivery on chain 4663 remain integration checks against live state; local fixture signatures and addresses are test data only. No implementation defect was reproduced by this suite.
