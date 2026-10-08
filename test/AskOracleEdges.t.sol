// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AskOracle} from "src/AskOracle.sol";
import {QuestionText} from "src/QuestionText.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Minimal ERC-1271 registry: approvals bind both the digest and exact signature bytes.
contract AskOracleTestRegistry {
    bytes32 internal approvedDigest;
    bytes32 internal approvedSignature;
    bool internal rejecting;

    function approve(bytes32 digest, bytes calldata signature, bool reject) external {
        approvedDigest = digest;
        approvedSignature = keccak256(signature);
        rejecting = reject;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        require(!rejecting, "registry unavailable");
        return
            digest == approvedDigest && keccak256(signature) == approvedSignature
                ? bytes4(0x1626ba7e)
                : bytes4(0xffffffff);
    }
}

contract AskOracleEdgesTest is Test {
    uint256 internal constant KEY = 0x123456;
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    AskOracle internal app;
    MockERC20 internal token;
    MockIntake internal intake;
    address internal user;
    address internal recipient;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        user = makeAddr("edge case asker");
        recipient = makeAddr("edge case fee recipient");
        token = new MockERC20();
        intake = new MockIntake(recipient);
        app = new AskOracle(address(this), address(intake), address(token), ACTION, vm.addr(KEY), 50, 40, 86400);
        token.mint(user, 100 ether);
        vm.prank(user);
        token.approve(address(app), type(uint256).max);
    }

    function test_EveryAttestationFieldIsCoveredByTheSignature() public {
        bytes32 intakeId = _ask("Are all fifteen fields authenticated?");
        bytes memory signature = _sign(_attestation());
        for (uint256 i; i < 15; ++i) {
            OracleAttestation.Attestation memory a = _attestation();
            if (i == 0) a.requestId = keccak256("tampered uuid");
            if (i == 1) ++a.chainId;
            if (i == 2) a.questionHash = keccak256("tampered question");
            if (i == 3) ++a.answerType;
            if (i == 4) a.answer = abi.encode(false);
            if (i == 5) ++a.figure;
            if (i == 6) ++a.fromBlock;
            if (i == 7) ++a.toBlock;
            if (i == 8) a.blockHash = keccak256("tampered block");
            if (i == 9) a.panelJobId = keccak256("tampered panel");
            if (i == 10) ++a.panelSize;
            if (i == 11) ++a.quorum;
            if (i == 12) ++a.agreed;
            if (i == 13) ++a.issuedAt;
            if (i == 14) --a.expiresAt;
            vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
            intake.deliver(intakeId, a, signature);
            _assertPending(1, a.requestId);
        }
        // Failed verifications cannot consume the genuine UUID or prevent a valid result.
        intake.deliver(intakeId, _attestation(), signature);
        assertEq(app.latestAnswered(), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AcceptsSufficientPanelsUnderStipend(
        uint16 panelSeed,
        uint16 quorumSeed,
        uint16 agreedSeed,
        bool value
    ) public {
        bytes32 intakeId = _ask("Did the required panel agree?");
        OracleAttestation.Attestation memory a = _attestation();
        a.panelSize = uint16(bound(panelSeed, 50, 300));
        a.quorum = uint16(bound(quorumSeed, 40, a.panelSize));
        a.agreed = uint16(bound(agreedSeed, a.quorum, a.panelSize));
        a.answer = abi.encode(value);
        bytes memory signature = _sign(a);
        vm.cool(address(app));
        vm.cool(vm.addr(KEY));
        assertLt(intake.deliver(intakeId, a, signature), 200_000);
        (,, AskOracle.Status state, bool answer, uint16 agreed, uint16 signedQuorum, uint16 signedPanel,,) =
            app.question(1);
        assertEq(uint256(state), uint256(AskOracle.Status.Answered));
        assertEq(answer, value);
        assertEq(agreed, a.agreed);
        assertEq(signedQuorum, a.quorum);
        assertEq(signedPanel, a.panelSize);
    }

    function test_ClockSkewToleranceInclusiveBoundary() public {
        bytes32 intakeId = _ask("Is the timestamp tolerance inclusive?");
        OracleAttestation.Attestation memory a = _attestation();
        a.issuedAt += 300;
        a.expiresAt = a.issuedAt + 86400;
        intake.deliver(intakeId, a, _sign(a));
        assertTrue(app.consumed(a.requestId));
        (,,,,,,,, uint64 answeredAt) = app.question(1);
        assertEq(answeredAt, block.timestamp);
    }

    function test_EmptyAndTrailingBoolBytesAreRejectedWithoutConsumption() public {
        bytes32 intakeId = _ask("Is bool decoding canonical?");
        OracleAttestation.Attestation memory a = _attestation();
        for (uint256 i; i < 3; ++i) {
            a.answer = i == 0 ? bytes("") : new bytes(i == 1 ? 31 : 64);
            bytes memory signature = _sign(a);
            vm.expectRevert(AskOracle.InvalidAttestation.selector);
            intake.deliver(intakeId, a, signature);
            _assertPending(1, a.requestId);
        }
    }

    function test_RegistrySignerAcceptsExactDigestAndRejectsWrongMagicOrRevert() public {
        bytes32 intakeId = _ask("Does a registry signer authenticate the result?");
        AskOracleTestRegistry registry = new AskOracleTestRegistry();
        app.setSigner(address(registry));
        OracleAttestation.Attestation memory a = _attestation();
        bytes memory signature = hex"01020304";
        bytes32 digest = app.attestationDigest(a);
        registry.approve(digest, signature, true);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(intakeId, a, signature);
        _assertPending(1, a.requestId);
        registry.approve(digest, signature, false);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(intakeId, a, hex"01020305");
        _assertPending(1, a.requestId);
        vm.cool(address(app));
        vm.cool(address(registry));
        assertLt(intake.deliver(intakeId, a, signature), 200_000);
        assertTrue(app.consumed(a.requestId));
        assertEq(app.latestAnswered(), 1);
    }

    function test_PriceLookupUsesConfiguredActionAndAsset() public {
        vm.expectCall(address(intake), abi.encodeCall(IIntake.priceOf, (ACTION, address(token))), 1);
        _ask("Is the configured asset quoted?");
        assertEq(token.balanceOf(recipient), 0.5 ether);
    }

    function test_OneWeiPriceAndFullBalanceArePaidExactly() public {
        _checkFullBalancePrice(1);
    }

    function test_MaxUintPriceAndFullBalanceArePaidExactly() public {
        _checkFullBalancePrice(type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FullBalancePriceIsNeverRounded(uint256 price) public {
        _checkFullBalancePrice(bound(price, 1, type(uint256).max));
    }

    function _checkFullBalancePrice(uint256 price) internal {
        MockERC20 payment = new MockERC20();
        app.setProtocol(address(intake), address(payment), ACTION);
        intake.setPrice(price);
        payment.mint(user, price);
        vm.prank(user);
        payment.approve(address(app), price);
        _ask("Is exactly the quoted price spent?");
        assertEq(payment.balanceOf(user), 0);
        assertEq(payment.balanceOf(recipient), price);
        assertEq(payment.balanceOf(address(app)), 0);
        assertEq(payment.allowance(address(app), address(intake)), 0);
        assertEq(intake.allowanceAtRequest(), price);
        assertEq(app.count(), 1);
    }

    function test_QuestionLengthIsBytesNotUnicodeCharacterCount() public {
        bytes memory text;
        for (uint256 i; i < 125; ++i) {
            text = bytes.concat(text, unicode"😀");
        }
        assertEq(text.length, 500);
        _ask(string(text));
        assertEq(vm.parseJsonString(string(intake.lastBody()), ".question"), string(text));
        vm.expectRevert(QuestionText.InvalidQuestion.selector);
        vm.prank(user);
        app.ask(string(bytes.concat(text, "?")));
        assertEq(app.count(), 1);
        assertEq(token.balanceOf(recipient), 0.5 ether);
    }

    function test_Utf8ScalarBoundariesRoundTrip() public {
        // Last/first valid scalars at every UTF-8 width, either side of surrogates, and U+10FFFF.
        bytes[9] memory scalars = [
            bytes(hex"7e"),
            hex"c2a0",
            hex"dfbf",
            hex"e0a080",
            hex"ed9fbf",
            hex"ee8080",
            hex"efbfbf",
            hex"f0908080",
            hex"f48fbfbf"
        ];
        for (uint256 i; i < scalars.length; ++i) {
            string memory text = string(bytes.concat('"', scalars[i], "\\?"));
            _ask(text);
            assertEq(vm.parseJsonString(string(intake.lastBody()), ".question"), text);
        }
    }

    function test_AllUnicodeControlScalarsRejectedAtomically() public {
        for (uint256 point = 0x80; point <= 0x9f; ++point) {
            vm.expectRevert(QuestionText.InvalidQuestion.selector);
            vm.prank(user);
            app.ask(string(abi.encodePacked("before", bytes1(0xc2), bytes1(uint8(point)), "after")));
        }
        assertEq(app.count(), 0);
        assertEq(token.balanceOf(user), 100 ether);
        assertEq(intake.nonce(), 0);
    }

    function test_JsonInjectionCannotAlterPolicyOrAddKeys() public {
        string memory text = 'Is this literal text? ","panelSize":2,"quorum":2,"consumer":"attacker"} \\"';
        _ask(text);
        string memory body = string(intake.lastBody());
        assertEq(vm.parseJsonString(body, ".question"), text);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 50);
        assertEq(vm.parseJsonUint(body, ".quorum"), 40);
        assertEq(vm.parseJsonUint(body, ".chainId"), 4663);
        assertEq(vm.parseJsonUint(body, ".window.hours"), 1);
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonKeys(body, "$").length, 9);
    }

    function test_QuoteFailureOccursBeforeAnyPayment() public {
        vm.mockCallRevert(address(intake), abi.encodeCall(IIntake.priceOf, (ACTION, address(token))), bytes("not sold"));
        vm.expectRevert(bytes("not sold"));
        vm.prank(user);
        app.ask("Is an unsold action rejected?");
        assertEq(app.count(), 0);
        assertEq(token.balanceOf(user), 100 ether);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(address(app), address(intake)), 0);
    }

    function _ask(string memory text) internal returns (bytes32 intakeId) {
        vm.prank(user);
        app.ask(text);
        return intake.lastRequestId();
    }

    function _attestation() internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256("edge oracle uuid");
        a.chainId = 4663;
        a.questionHash = keccak256("resolved question document");
        a.answer = abi.encode(true);
        a.figure = 12345;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("end block");
        a.panelJobId = keccak256("edge panel job");
        a.panelSize = 50;
        a.quorum = 40;
        a.agreed = 43;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 86400);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, app.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _assertPending(uint256 id, bytes32 uuid) internal view {
        (,, AskOracle.Status state,,,,,, uint64 answeredAt) = app.question(id);
        assertEq(uint256(state), uint256(AskOracle.Status.Pending));
        assertEq(answeredAt, 0);
        assertEq(app.latestAnswered(), 0);
        assertFalse(app.consumed(uuid));
    }
}
