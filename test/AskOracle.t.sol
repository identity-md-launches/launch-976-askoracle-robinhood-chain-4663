// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskOracle} from "../src/AskOracle.sol";
import {QuestionText} from "../src/QuestionText.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

contract AskOracleTest is Test {
    AskOracle internal app;
    MockERC20 internal token;
    MockIntake internal intake;
    address internal alice;
    address internal bob;
    address internal recipient;
    uint256 internal constant SIGNER_KEY = 123456;
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 internal constant PRICE = 0.5 ether;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        recipient = makeAddr("intake fee recipient");
        token = new MockERC20();
        intake = new MockIntake(recipient);
        app = new AskOracle(address(this), address(intake), address(token), ACTION, vm.addr(SIGNER_KEY), 50, 40, 86400);
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(app), 100 ether);
    }

    function askOne() internal returns (uint256 id, bytes32 requestId) {
        vm.prank(alice);
        id = app.ask("Is the sky blue?");
        requestId = intake.lastRequestId();
    }

    function attestation(bytes32 uuid, bool answer) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = uuid;
        a.chainId = 4663;
        a.questionHash = keccak256("canonical question, resolved window and definitions");
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(answer);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("closing block");
        a.panelJobId = keccak256("panel job");
        a.panelSize = 50;
        a.quorum = 40;
        a.agreed = 43;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, app.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function status(uint256 id) internal view returns (AskOracle.Status state) {
        (,, state,,,,,,) = app.question(id);
    }

    function test_AskExactBodyPaymentAndPendingRecord() public {
        (uint256 id, bytes32 requestId) = askOne();
        assertEq(id, 1);
        assertEq(app.count(), 1);
        assertEq(app.latestAnswered(), 0);
        assertEq(
            string(intake.lastBody()),
            '{"v":1,"question":"Is the sky blue?","chainId":4663,"window":{"hours":1},"answerType":"bool","evidence":"panel","panelSize":50,"quorum":40,"validForSeconds":86400}'
        );
        assertEq(intake.lastAction(), ACTION);
        assertEq(intake.lastAsset(), address(token));
        assertEq(intake.lastAmount(), PRICE);
        assertEq(intake.allowanceAtRequest(), PRICE);
        assertEq(token.balanceOf(alice), 100 ether - PRICE);
        assertEq(token.balanceOf(recipient), PRICE);
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(token.allowance(address(app), address(intake)), 0);
        (address target, bytes4 selector) = intake.callbacks(requestId);
        assertEq(target, address(app));
        assertEq(selector, app.onOracleResult.selector);
        {
            (
                address asker,
                string memory text,
                AskOracle.Status state,
                bool answer,
                uint16 agreed,
                uint16 q,
                uint16 panel,
                uint64 askedAt,
                uint64 answeredAt
            ) = app.question(id);
            assertEq(asker, alice);
            assertEq(text, "Is the sky blue?");
            assertEq(uint256(state), uint256(AskOracle.Status.Pending));
            assertFalse(answer);
            assertEq(uint256(agreed) + q + panel + answeredAt, 0);
            assertEq(askedAt, block.timestamp);
        }
        (address origin, bytes32 storedId, uint16 requestedPanel, uint16 requestedQuorum, uint32 validity) =
            app.requestDetails(id);
        assertEq(origin, address(intake));
        assertEq(storedId, requestId);
        assertEq(requestedPanel, 50);
        assertEq(requestedQuorum, 40);
        assertEq(validity, 86400);
    }

    function test_JsonEscapesQuotesAndBackslashesWithoutChangingStoredQuestion() public {
        string memory text = 'Is "C:\\foo" a path?';
        vm.prank(alice);
        uint256 id = app.ask(text);
        (, string memory stored,,,,,,,) = app.question(id);
        assertEq(stored, text);
        assertEq(
            string(intake.lastBody()),
            '{"v":1,"question":"Is \\"C:\\\\foo\\" a path?","chainId":4663,"window":{"hours":1},"answerType":"bool","evidence":"panel","panelSize":50,"quorum":40,"validForSeconds":86400}'
        );
    }

    function test_ValidUnicodeAndLengthBoundaries() public {
        vm.startPrank(alice);
        app.ask("?");
        app.ask(unicode"Ist Köln schön? 😀");
        bytes memory full = new bytes(500);
        for (uint256 i; i < full.length; ++i) {
            full[i] = 0x22;
        }
        app.ask(string(full));
        vm.expectRevert(QuestionText.InvalidQuestion.selector);
        app.ask(string(bytes.concat(full, "?")));
        vm.expectRevert(QuestionText.InvalidQuestion.selector);
        app.ask("");
        vm.stopPrank();
        assertEq(app.count(), 3);
    }

    function testFuzz_JsonRoundTripForPrintableAscii(bytes memory input) public {
        vm.assume(input.length > 0 && input.length <= 500);
        for (uint256 i; i < input.length; ++i) {
            input[i] = bytes1(uint8(32 + uint8(input[i]) % 95));
        }
        vm.prank(alice);
        uint256 id = app.ask(string(input));
        assertEq(vm.parseJsonString(string(intake.lastBody()), ".question"), string(input));
        (, string memory stored,,,,,,,) = app.question(id);
        assertEq(stored, string(input));
    }

    function test_InvalidUtf8AndUnicodeControls() public {
        bytes[11] memory invalid = [
            bytes(hex"80"),
            hex"c0af",
            hex"c1bf",
            hex"c280",
            hex"c29f",
            hex"e080af",
            hex"eda080",
            hex"f4908080",
            hex"f5808080",
            hex"e282",
            hex"c241"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(QuestionText.InvalidQuestion.selector);
            vm.prank(alice);
            app.ask(string(invalid[i]));
        }
        assertEq(app.count(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function testFuzz_AsciiControlsRejected(uint8 control) public {
        control = uint8(bound(control, 0, 32));
        bytes1 value = control == 32 ? bytes1(0x7f) : bytes1(control);
        vm.expectRevert(QuestionText.InvalidQuestion.selector);
        vm.prank(alice);
        app.ask(string(abi.encodePacked("question", value, "?")));
    }

    function test_PriceIsReadForEveryRequest() public {
        askOne();
        intake.setPrice(0.7 ether);
        askOne();
        assertEq(token.balanceOf(recipient), 1.2 ether);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_NoAllowanceOrInsufficientBalanceRevertsAtomically() public {
        vm.prank(alice);
        token.approve(address(app), 0);
        vm.expectRevert();
        askOne();
        vm.prank(bob);
        token.approve(address(app), PRICE);
        vm.expectRevert();
        vm.prank(bob);
        app.ask("Enough funds?");
        assertEq(app.count(), 0);
    }

    function test_FailedOrIncompleteIntakePaymentRollsBack() public {
        intake.setBehavior(true, false, false);
        vm.expectRevert("intake failed");
        askOne();
        intake.setBehavior(false, true, false);
        vm.expectRevert(AskOracle.InvalidPayment.selector);
        askOne();
        intake.setPrice(0);
        vm.expectRevert(AskOracle.InvalidPayment.selector);
        askOne();
        assertEq(app.count(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.allowance(address(app), address(intake)), 0);
    }

    function test_RejectsFalseReturningAndFeeTokens() public {
        token.setBehavior(true, false, false, false);
        vm.expectRevert();
        askOne();
        token.setBehavior(false, false, true, false);
        vm.expectRevert(AskOracle.InvalidPayment.selector);
        askOne();
        assertEq(app.count(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_NoReturnTokenAndZeroFirstApprovalWork() public {
        token.setBehavior(false, true, false, true);
        askOne();
        askOne();
        assertEq(token.balanceOf(recipient), PRICE * 2);
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(token.allowance(address(app), address(intake)), 0);
    }

    function test_DuplicateIntakeIdRevertsPaymentAndRecord() public {
        askOne();
        intake.setBehavior(false, false, true);
        vm.expectRevert(AskOracle.DuplicateRequest.selector);
        askOne();
        assertEq(app.count(), 1);
        assertEq(token.balanceOf(recipient), PRICE);
    }

    function test_ReentrantTokenAndIntakeCannotAskAgain() public {
        token.setHook(address(app), abi.encodeCall(app.ask, ("recursive token ask")));
        intake.setHook(address(app), abi.encodeCall(app.ask, ("recursive intake ask")));
        askOne();
        assertFalse(token.hookSucceeded());
        assertFalse(intake.hookSucceeded());
        assertEq(app.count(), 1);
        assertEq(token.balanceOf(recipient), PRICE);
    }

    function test_YesAndNoAnswersAndOutOfOrderLatest() public {
        (uint256 id1, bytes32 request1) = askOne();
        (uint256 id2, bytes32 request2) = askOne();
        OracleAttestation.Attestation memory no = attestation(keccak256("oracle uuid 2"), false);
        intake.deliver(request2, no, sign(no));
        assertEq(app.latestAnswered(), id2);
        assertEq(uint256(status(id2)), uint256(AskOracle.Status.Answered));
        (,,, bool answer2,,,,,) = app.question(id2);
        assertFalse(answer2);
        vm.warp(block.timestamp + 17);
        OracleAttestation.Attestation memory yes = attestation(keccak256("oracle uuid 1"), true);
        intake.deliver(request1, yes, sign(yes));
        assertEq(app.latestAnswered(), id1);
        (,, AskOracle.Status state, bool answer, uint16 agreed, uint16 q, uint16 panel,, uint64 answeredAt) =
            app.question(id1);
        assertEq(uint256(state), uint256(AskOracle.Status.Answered));
        assertTrue(answer);
        assertEq(agreed, 43);
        assertEq(q, 40);
        assertEq(panel, 50);
        assertEq(answeredAt, block.timestamp);
        assertTrue(app.consumed(yes.requestId));
        assertTrue(app.consumed(no.requestId));
    }

    function test_WrongSenderAndUnknownRequest() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
        bytes memory signature = sign(a);
        vm.expectRevert(AskOracle.OnlyIntake.selector);
        app.onOracleResult(requestId, a, signature);
        vm.expectRevert(AskOracle.UnknownRequest.selector);
        vm.prank(address(intake));
        app.onOracleResult(keccak256("unknown"), a, signature);
    }

    function test_ReplaySameCallbackOrUuidAcrossQuestionsFails() public {
        (, bytes32 requestId) = askOne();
        (, bytes32 second) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
        bytes memory signature = sign(a);
        intake.deliver(requestId, a, signature);
        vm.expectRevert(AskOracle.NotPending.selector);
        intake.deliver(requestId, a, signature);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        intake.deliver(second, a, signature);
        assertEq(uint256(status(2)), uint256(AskOracle.Status.Pending));
    }

    function test_TamperedExpiredFutureAndMalformedSignatures() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
        bytes memory signature = sign(a);
        a.figure = 1;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(requestId, a, signature);
        a.figure = 0;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(requestId, a, hex"01");
        a.expiresAt = uint64(block.timestamp - 1);
        signature = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        intake.deliver(requestId, a, signature);
        a = attestation(keccak256("uuid"), true);
        a.issuedAt += 301;
        signature = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        intake.deliver(requestId, a, signature);
        assertFalse(app.consumed(a.requestId));
    }

    function test_WrongDomainContractAndChainFail() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
        AskOracle other =
            new AskOracle(address(this), address(intake), address(token), ACTION, vm.addr(SIGNER_KEY), 50, 40, 86400);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(requestId, a, abi.encodePacked(r, s, v));
        vm.chainId(1);
        bytes memory signature = sign(a);
        vm.chainId(4663);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(requestId, a, signature);
    }

    function test_InvalidSignedTypeAndMalformedBool() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
        a.answerType = 3;
        bytes memory signature = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(0), uint8(3)));
        intake.deliver(requestId, a, signature);
        a.answerType = 0;
        a.answer = abi.encode(uint256(2));
        signature = sign(a);
        vm.expectRevert();
        intake.deliver(requestId, a, signature);
        a.answer = hex"01";
        signature = sign(a);
        vm.expectRevert(AskOracle.InvalidAttestation.selector);
        intake.deliver(requestId, a, signature);
    }

    function test_InvalidSignedPanelChainWindowAndValidity() public {
        (, bytes32 requestId) = askOne();
        for (uint256 i; i < 10; ++i) {
            OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
            if (i == 0) a.agreed = 39;
            if (i == 1) a.panelSize = 49;
            if (i == 2) a.quorum = 39;
            if (i == 3) a.quorum = 51;
            if (i == 4) a.agreed = 51;
            if (i == 5) a.chainId = 1;
            if (i == 6) a.expiresAt++;
            if (i == 7) a.issuedAt--;
            if (i == 8) a.fromBlock = 201;
            if (i == 9) a.panelSize = 301;
            bytes memory signature = sign(a);
            vm.expectRevert(AskOracle.InvalidAttestation.selector);
            intake.deliver(requestId, a, signature);
            assertFalse(app.consumed(a.requestId));
        }
    }

    function test_TimeoutBoundaryAnyoneCanMarkAndFeeIsSpent() public {
        (uint256 id, bytes32 requestId) = askOne();
        uint256 asked = block.timestamp;
        vm.warp(asked + 1 days - 1);
        vm.expectRevert(AskOracle.TooEarly.selector);
        app.markUnanswered(id);
        vm.warp(asked + 1 days);
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
        bytes memory signature = sign(a);
        vm.expectRevert(AskOracle.DeadlinePassed.selector);
        intake.deliver(requestId, a, signature);
        vm.prank(bob);
        app.markUnanswered(id);
        assertEq(uint256(status(id)), uint256(AskOracle.Status.Unanswered));
        assertEq(token.balanceOf(recipient), PRICE);
        assertEq(token.balanceOf(alice), 100 ether - PRICE);
        assertEq(app.latestAnswered(), 0);
        vm.expectRevert(AskOracle.NotPending.selector);
        app.markUnanswered(id);
        vm.expectRevert(AskOracle.NotPending.selector);
        intake.deliver(requestId, a, signature);
    }

    function test_AnswerAcceptedJustBeforeDeadlineAndAtSignatureExpiry() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("deadline uuid"), false);
        a.expiresAt = uint64(block.timestamp + 1 days - 1);
        bytes memory signature = sign(a);
        vm.warp(a.expiresAt);
        intake.deliver(requestId, a, signature);
        assertEq(uint256(status(1)), uint256(AskOracle.Status.Answered));
    }

    function test_ExpiryBeforeIssuanceFailsEvenWithinClockTolerance() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("invalid interval"), false);
        a.expiresAt = uint64(block.timestamp + 1);
        a.issuedAt = uint64(block.timestamp + 2);
        bytes memory signature = sign(a);
        vm.expectRevert(AskOracle.InvalidAttestation.selector);
        intake.deliver(requestId, a, signature);
    }

    function test_MalleableHighSSignatureRejected() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("malleable uuid"), true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, app.attestationDigest(a));
        uint256 order = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes32 highS = bytes32(order - uint256(s));
        bytes memory signature = abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(requestId, a, signature);
    }

    function test_DonationsDoNotSubsidizeQuestionsAndNativePaymentsRejected() public {
        token.mint(address(app), 2 ether);
        askOne();
        assertEq(token.balanceOf(address(app)), 2 ether);
        assertEq(token.balanceOf(alice), 100 ether - PRICE);
        assertEq(token.allowance(address(app), address(intake)), 0);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(app).call{value: 1}("");
        assertFalse(ok);
    }

    function test_AnsweredCannotBeMarkedUnanswered() public {
        (uint256 id, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), false);
        intake.deliver(requestId, a, sign(a));
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(AskOracle.NotPending.selector);
        app.markUnanswered(id);
    }

    function test_UnknownGettersAndTimeoutFail() public {
        vm.expectRevert(AskOracle.UnknownQuestion.selector);
        app.question(0);
        vm.expectRevert(AskOracle.UnknownQuestion.selector);
        app.question(1);
        vm.expectRevert(AskOracle.UnknownQuestion.selector);
        app.requestDetails(1);
        vm.expectRevert(AskOracle.UnknownQuestion.selector);
        app.markUnanswered(1);
    }

    function test_ConfigurationChangesAreOwnerOnlyAndValidateBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(AskOracle.OnlyOwner.selector);
        app.setSigner(alice);
        vm.expectRevert(AskOracle.OnlyOwner.selector);
        app.setProtocol(address(intake), address(token), ACTION);
        vm.expectRevert(AskOracle.OnlyOwner.selector);
        app.setPanel(50, 40, 86400);
        vm.stopPrank();
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        app.setSigner(address(0));
        vm.expectRevert(AskOracle.InvalidConfiguration.selector);
        app.setProtocol(address(0), address(token), ACTION);
        vm.expectRevert(AskOracle.InvalidConfiguration.selector);
        app.setProtocol(address(intake), address(0), ACTION);
        vm.expectRevert(AskOracle.InvalidConfiguration.selector);
        app.setProtocol(address(intake), address(token), bytes32(0));
        uint16[4] memory panels = [uint16(1), 301, 50, 50];
        uint16[4] memory quorums = [uint16(1), 40, 1, 51];
        for (uint256 i; i < panels.length; ++i) {
            vm.expectRevert(AskOracle.InvalidConfiguration.selector);
            app.setPanel(panels[i], quorums[i], 86400);
        }
        vm.expectRevert(AskOracle.InvalidConfiguration.selector);
        app.setPanel(50, 40, 59);
        vm.expectRevert(AskOracle.InvalidConfiguration.selector);
        app.setPanel(50, 40, 30 days + 1);
        app.setPanel(2, 2, 60);
        app.setPanel(300, 300, 30 days);
    }

    function test_PendingPanelPolicyAndIntakeSurviveRotation() public {
        (, bytes32 oldId) = askOne();
        app.setPanel(100, 80, 3600);
        MockIntake nextIntake = new MockIntake(recipient);
        MockERC20 nextToken = new MockERC20();
        bytes32 nextAction = bytes32("oracle.request@oracle-2");
        app.setProtocol(address(nextIntake), address(nextToken), nextAction);
        OracleAttestation.Attestation memory a = attestation(keccak256("old uuid"), true);
        intake.deliver(oldId, a, sign(a));
        assertEq(app.latestAnswered(), 1);
        nextToken.mint(alice, PRICE);
        vm.startPrank(alice);
        nextToken.approve(address(app), PRICE);
        uint256 id = app.ask("New policy?");
        vm.stopPrank();
        assertEq(nextIntake.lastAction(), nextAction);
        assertEq(
            string(nextIntake.lastBody()),
            '{"v":1,"question":"New policy?","chainId":4663,"window":{"hours":1},"answerType":"bool","evidence":"panel","panelSize":100,"quorum":80,"validForSeconds":3600}'
        );
        a.requestId = keccak256("new uuid");
        bytes memory signature = sign(a);
        bytes32 newRequestId = nextIntake.lastRequestId();
        vm.expectRevert(AskOracle.InvalidAttestation.selector);
        nextIntake.deliver(newRequestId, a, signature);
        a.panelSize = 100;
        a.quorum = 80;
        a.agreed = 80;
        a.expiresAt = a.issuedAt + 3600;
        nextIntake.deliver(nextIntake.lastRequestId(), a, sign(a));
        assertEq(app.latestAnswered(), id);
    }

    function test_SignerRotationAppliesToPendingRequests() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("uuid"), true);
        bytes memory oldSignature = sign(a);
        app.setSigner(vm.addr(987654));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(requestId, a, oldSignature);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(987654, app.attestationDigest(a));
        intake.deliver(requestId, a, abi.encodePacked(r, s, v));
        assertEq(app.latestAnswered(), 1);
    }

    function test_FirstCallbackWithColdStorageFitsStipend() public {
        (, bytes32 requestId) = askOne();
        OracleAttestation.Attestation memory a = attestation(keccak256("cold uuid"), true);
        bytes memory signature = sign(a);
        vm.cool(address(app));
        vm.cool(vm.addr(SIGNER_KEY));
        uint256 used = intake.deliver(requestId, a, signature);
        emit log_named_uint("Cold callback gas including CALL overhead", used);
        assertLt(used, 200_000);
        assertEq(app.latestAnswered(), 1);
    }

    function test_ConstructorUsesExplicitOwnerAndRejectsZeroOwner() public {
        AskOracle owned =
            new AskOracle(bob, address(intake), address(token), ACTION, vm.addr(SIGNER_KEY), 50, 40, 86400);
        assertEq(owned.owner(), bob);
        vm.expectRevert(AskOracle.OnlyOwner.selector);
        owned.setPanel(60, 40, 86400);
        vm.prank(bob);
        owned.setPanel(60, 40, 86400);
        address signer = vm.addr(SIGNER_KEY);
        vm.expectRevert(AskOracle.InvalidConfiguration.selector);
        new AskOracle(address(0), address(intake), address(token), ACTION, signer, 50, 40, 86400);
    }

    function test_ApplicationRuntimeBoundedAndNoForbiddenOpcodes() public view {
        bytes memory code = address(app).code;
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_FeeConservation(uint8 asks) public {
        asks = uint8(bound(asks, 1, 20));
        for (uint256 i; i < asks; ++i) {
            askOne();
        }
        assertEq(token.balanceOf(recipient), uint256(asks) * PRICE);
        assertEq(token.balanceOf(alice) + token.balanceOf(recipient), 100 ether);
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(token.allowance(address(app), address(intake)), 0);
        assertEq(app.count(), asks);
    }
}
