// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskOracle} from "src/AskOracle.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Ghosts come from caller inputs and successful operations, never from question() output.
/// Only the explicitly selected entry points are fuzzed; mocks and cheatcodes are not targets.
contract AskOracleHandler is Test {
    struct ExpectedQuestion {
        address asker;
        string text;
        uint8 route;
        bytes32 intakeId;
        uint64 askedAt;
        uint64 answeredAt;
        uint16 panel;
        uint16 quorum;
        uint32 validity;
        AskOracle.Status status;
        bool answer;
    }

    uint256 public constant INITIAL_BALANCE = 1_000_000 ether;
    uint256 internal constant KEY_ONE = 0x5151;
    uint256 internal constant KEY_TWO = 0x6262;
    AskOracle public app;
    MockERC20[2] public tokens;
    MockIntake[2] public intakes;
    address[3] public actors;
    address public recipient;
    uint256 public asked;
    uint256 public answered;
    uint256 public timedOut;
    uint256 public latest;
    uint256 public rejectedPayments;
    uint256 public rejectedCallbacks;
    uint256[2] public fees;
    uint256[2] public donations;
    uint256[2] public prices;
    mapping(uint256 => mapping(address => uint256)) public spent;
    mapping(uint256 => mapping(address => uint256)) public donated;
    mapping(uint256 => ExpectedQuestion) internal expected;
    uint8 public route;
    uint16 public panel = 50;
    uint16 public quorum = 40;
    uint32 public validity = 86400;
    uint256 internal signerKey = KEY_ONE;

    constructor() {
        recipient = makeAddr("invariant fee recipient");
        actors = [makeAddr("invariant alice"), makeAddr("invariant bob"), makeAddr("invariant carol")];
        for (uint256 i; i < 2; ++i) {
            tokens[i] = new MockERC20();
            intakes[i] = new MockIntake(recipient);
            prices[i] = 0.5 ether;
        }
        app = new AskOracle(
            address(this),
            address(intakes[0]),
            address(tokens[0]),
            _action(0),
            vm.addr(signerKey),
            panel,
            quorum,
            validity
        );
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                tokens[i].mint(actors[j], INITIAL_BALANCE);
                vm.prank(actors[j]);
                tokens[i].approve(address(app), type(uint256).max);
            }
        }
    }

    function ask(uint256 actorSeed, bytes32 textSeed, uint16 lengthSeed) public {
        address actor = actors[actorSeed % actors.length];
        bytes memory text = new bytes(bound(lengthSeed, 1, 500));
        for (uint256 i; i < text.length; ++i) {
            text[i] = bytes1(uint8(32 + uint8(textSeed[i % 32]) % 95));
        }
        vm.prank(actor);
        uint256 id = app.ask(string(text));
        ++asked;
        assertEq(id, asked, "successful asks must allocate one consecutive id");
        fees[route] += prices[route];
        spent[route][actor] += prices[route];
        expected[id] = ExpectedQuestion({
            asker: actor,
            text: string(text),
            route: route,
            intakeId: intakes[route].lastRequestId(),
            askedAt: uint64(block.timestamp),
            answeredAt: 0,
            panel: panel,
            quorum: quorum,
            validity: validity,
            status: AskOracle.Status.Pending,
            answer: false
        });
        string memory body = string(intakes[route].lastBody());
        assertEq(vm.parseJsonString(body, ".question"), string(text));
        assertEq(vm.parseJsonUint(body, ".panelSize"), panel);
        assertEq(vm.parseJsonUint(body, ".quorum"), quorum);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), validity);
        assertEq(intakes[route].lastAction(), _action(route));
        assertEq(intakes[route].lastAsset(), address(tokens[route]));
        assertEq(intakes[route].allowanceAtRequest(), prices[route]);
    }

    // Repeated delivery and late delivery must fail without disturbing the original result.
    function answer(uint256 idSeed, bool value) public {
        uint256 id = bound(idSeed, 1, asked);
        ExpectedQuestion storage q = expected[id];
        OracleAttestation.Attestation memory a = _attestation(id, value);
        bytes memory signature = _sign(a);
        if (q.status != AskOracle.Status.Pending) {
            vm.expectRevert(AskOracle.NotPending.selector);
        } else if (block.timestamp >= uint256(q.askedAt) + 1 days) {
            vm.expectRevert(AskOracle.DeadlinePassed.selector);
        } else {
            vm.cool(address(app));
            vm.cool(vm.addr(signerKey));
            uint256 gasUsed = intakes[q.route].deliver(q.intakeId, a, signature);
            assertLt(gasUsed, 200_000, "callback exceeded stipend");
            q.status = AskOracle.Status.Answered;
            q.answer = value;
            q.answeredAt = uint64(block.timestamp);
            latest = id;
            ++answered;
            return;
        }
        intakes[q.route].deliver(q.intakeId, a, signature);
        ++rejectedCallbacks;
    }

    function expire(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = bound(idSeed, 1, asked);
        ExpectedQuestion storage q = expected[id];
        vm.prank(actors[actorSeed % actors.length]);
        if (q.status != AskOracle.Status.Pending) {
            vm.expectRevert(AskOracle.NotPending.selector);
        } else if (block.timestamp < uint256(q.askedAt) + 1 days) {
            vm.expectRevert(AskOracle.TooEarly.selector);
        } else {
            app.markUnanswered(id);
            q.status = AskOracle.Status.Unanswered;
            ++timedOut;
            return;
        }
        app.markUnanswered(id);
    }

    function advanceTime(uint32 delta) public {
        vm.warp(block.timestamp + bound(delta, 0, 1 days + 1));
    }

    function configure(uint8 routeSeed, uint16 panelSeed, uint16 quorumSeed, uint32 validitySeed, uint96 priceSeed)
        public
    {
        route = routeSeed % 2;
        panel = uint16(bound(panelSeed, 2, 300));
        quorum = uint16(bound(quorumSeed, 2, panel));
        validity = uint32(bound(validitySeed, 60, 30 days));
        prices[route] = bound(priceSeed, 1, 10 ether);
        intakes[route].setPrice(prices[route]);
        app.setProtocol(address(intakes[route]), address(tokens[route]), _action(route));
        app.setPanel(panel, quorum, validity);
        signerKey = signerKey == KEY_ONE ? KEY_TWO : KEY_ONE;
        app.setSigner(vm.addr(signerKey));
    }

    // Donations are separate from fees: even with a positive balance, the caller owes the whole price.
    function donate(uint8 tokenSeed, uint256 actorSeed, uint96 amountSeed) public {
        uint256 index = tokenSeed % 2;
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, 10 ether);
        vm.prank(actor);
        tokens[index].transfer(address(app), amount);
        donations[index] += amount;
        donated[index][actor] += amount;
    }

    function failedAsk(uint256 actorSeed, bool missingApproval) public {
        address actor = actors[actorSeed % actors.length];
        if (missingApproval) {
            vm.prank(actor);
            tokens[route].approve(address(app), prices[route] - 1);
        } else {
            intakes[route].setBehavior(false, true, false);
        }
        // The failed operation must roll back balances, the Intake nonce, mappings and count.
        uint256 nonce = intakes[route].nonce();
        if (missingApproval) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, address(app), prices[route] - 1, prices[route]
                )
            );
        } else {
            vm.expectRevert(AskOracle.InvalidPayment.selector);
        }
        vm.prank(actor);
        app.ask("Must an unpaid question be rejected?");
        assertEq(intakes[route].nonce(), nonce);
        if (missingApproval) {
            vm.prank(actor);
            tokens[route].approve(address(app), type(uint256).max);
        } else {
            intakes[route].setBehavior(false, false, false);
        }
        ++rejectedPayments;
    }

    function unauthorized(uint256 actorSeed, uint8 operation) public {
        address actor = actors[actorSeed % actors.length];
        vm.expectRevert(AskOracle.OnlyOwner.selector);
        vm.prank(actor);
        if (operation % 3 == 0) app.setSigner(actor);
        else if (operation % 3 == 1) app.setPanel(2, 2, 60);
        else app.setProtocol(address(intakes[1 - route]), address(tokens[1 - route]), _action(1 - route));
    }

    function replayAcrossRequests(uint256 sourceSeed, uint256 destinationSeed) public {
        uint256 source = bound(sourceSeed, 1, asked);
        uint256 destination = bound(destinationSeed, 1, asked);
        ExpectedQuestion storage q = expected[destination];
        if (
            expected[source].status != AskOracle.Status.Answered || q.status != AskOracle.Status.Pending
                || block.timestamp >= uint256(q.askedAt) + 1 days
        ) return;
        OracleAttestation.Attestation memory a = _attestation(destination, true);
        a.requestId = _uuid(source);
        bytes memory signature = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        intakes[q.route].deliver(q.intakeId, a, signature);
        ++rejectedCallbacks;
    }

    function assertAccounting() public view {
        assertEq(app.count(), asked, "phantom or missing question");
        assertEq(address(app).balance, 0);
        for (uint256 i; i < 2; ++i) {
            assertEq(tokens[i].balanceOf(address(app)), donations[i], "fees left behind or donations spent");
            assertEq(tokens[i].balanceOf(recipient), fees[i], "fee recipient did not receive exact prices");
            assertEq(tokens[i].balanceOf(address(intakes[i])), 0);
            uint256 sum = donations[i] + fees[i];
            for (uint256 j; j < actors.length; ++j) {
                uint256 balance = tokens[i].balanceOf(actors[j]);
                assertEq(balance + spent[i][actors[j]] + donated[i][actors[j]], INITIAL_BALANCE);
                sum += balance;
            }
            assertEq(sum, 3 * INITIAL_BALANCE, "value not conserved");
            assertEq(tokens[i].totalSupply(), 3 * INITIAL_BALANCE);
            for (uint256 j; j < 2; ++j) {
                assertEq(tokens[i].allowance(address(app), address(intakes[j])), 0, "stale approval");
            }
        }
    }

    function assertStateMachine() public view {
        assertEq(app.latestAnswered(), latest, "latest must follow delivery order");
        uint256 seenAnswered;
        uint256 seenUnanswered;
        for (uint256 id = 1; id <= asked; ++id) {
            _assertQuestion(id);
            if (expected[id].status == AskOracle.Status.Answered) ++seenAnswered;
            if (expected[id].status == AskOracle.Status.Unanswered) ++seenUnanswered;
        }
        assertEq(seenAnswered, answered);
        assertEq(seenUnanswered, timedOut);
        assertEq(app.owner(), address(this));
        assertEq(address(app.intake()), address(intakes[route]));
        assertEq(address(app.imd()), address(tokens[route]));
        assertEq(app.action(), _action(route));
        assertEq(app.panelSize(), panel);
        assertEq(app.quorum(), quorum);
        assertEq(app.validForSeconds(), validity);
        assertEq(app.oracleSigner(), vm.addr(signerKey));
    }

    function _assertQuestion(uint256 id) internal view {
        ExpectedQuestion storage q = expected[id];
        {
            (
                address asker,
                string memory text,
                AskOracle.Status state,
                bool value,
                uint16 agreed,
                uint16 signedQuorum,
                uint16 signedPanel,
                uint64 askedAt,
                uint64 answeredAt
            ) = app.question(id);
            bool isAnswered = q.status == AskOracle.Status.Answered;
            assertEq(asker, q.asker);
            assertEq(text, q.text);
            assertEq(uint256(state), uint256(q.status), "terminal request changed state");
            assertEq(value, q.answer);
            assertEq(askedAt, q.askedAt);
            assertEq(answeredAt, q.answeredAt);
            assertEq(agreed, isAnswered ? q.quorum : 0);
            assertEq(signedQuorum, isAnswered ? q.quorum : 0);
            assertEq(signedPanel, isAnswered ? q.panel : 0);
            assertEq(app.consumed(_uuid(id)), isAnswered, "uuid consumption disagrees with result");
        }
        (address origin, bytes32 intakeId, uint16 requestedPanel, uint16 requestedQuorum, uint32 requestedValidity) =
            app.requestDetails(id);
        assertEq(origin, address(intakes[q.route]));
        assertEq(intakeId, q.intakeId);
        assertEq(app.questionIdFor(origin, intakeId), id);
        assertEq(requestedPanel, q.panel, "pending policy overwritten");
        assertEq(requestedQuorum, q.quorum);
        assertEq(requestedValidity, q.validity);
    }

    function _attestation(uint256 id, bool value) internal view returns (OracleAttestation.Attestation memory a) {
        ExpectedQuestion storage q = expected[id];
        a.requestId = _uuid(id);
        a.chainId = 4663;
        a.questionHash = keccak256(abi.encode(q.text, q.askedAt));
        a.answer = abi.encode(value);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.panelSize = q.panel;
        a.quorum = q.quorum;
        a.agreed = q.quorum;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + q.validity);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, app.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _uuid(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode("invariant oracle uuid", id));
    }

    function _action(uint256 index) internal pure returns (bytes32) {
        return index == 0 ? bytes32("oracle.request@oracle-1") : bytes32("oracle.request@oracle-2");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AskOracleInvariantTest is Test {
    AskOracleHandler internal handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        handler = new AskOracleHandler();
        // Each campaign starts with both a delivered "no" and a pending request.
        handler.ask(0, bytes32("Is this a question?"), 19);
        handler.ask(1, bytes32("Another question?"), 17);
        handler.answer(1, false);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.ask.selector;
        selectors[1] = handler.answer.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.configure.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.failedAsk.selector;
        selectors[7] = handler.unauthorized.selector;
        selectors[8] = handler.replayAcrossRequests.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_FeesConservedAndNoResidualApprovals() public view {
        handler.assertAccounting();
    }

    function invariant_RequestRecordsAndTerminalStatesMatchHistory() public view {
        handler.assertStateMachine();
    }

    // Deterministically exercise the model's success, replay, rotation, failure and timeout branches.
    function test_HandlerExercisesBothTerminalStatesAndRollback() public {
        handler.replayAcrossRequests(1, 2);
        handler.failedAsk(0, true);
        handler.failedAsk(1, false);
        handler.donate(0, 2, 1 ether);
        handler.configure(1, 300, 299, 60, 1);
        handler.answer(2, true);
        handler.ask(2, bytes32("Policy changed?"), 500);
        handler.advanceTime(1 days);
        handler.expire(3, 0);
        handler.answer(3, true);
        handler.expire(2, 1);
        handler.unauthorized(0, 0);
        handler.unauthorized(1, 1);
        handler.unauthorized(2, 2);
        handler.assertAccounting();
        handler.assertStateMachine();
        assertEq(handler.answered(), 2);
        assertEq(handler.timedOut(), 1);
        assertEq(handler.rejectedPayments(), 2);
        assertEq(handler.rejectedCallbacks(), 2);
    }
}
