// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {QuestionText} from "./QuestionText.sol";

/// @notice Buys asynchronous yes/no answers on Robinhood Chain. Fees are spent immediately.
contract AskOracle is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Pending,
        Answered,
        Unanswered
    }

    struct Question {
        address asker;
        uint16 requestedPanelSize;
        uint16 requestedQuorum;
        uint32 requestedValidity;
        string text;
        bytes32 intakeRequestId;
        address intake;
        uint64 askedAt;
        Status status;
        bool answer;
        uint16 agreed;
        uint16 quorum;
        uint16 panelSize;
        uint64 answeredAt;
    }

    error OnlyOwner();
    error InvalidConfiguration();
    error UnknownQuestion();
    error UnknownRequest();
    error OnlyIntake();
    error NotPending();
    error DeadlinePassed();
    error TooEarly();
    error InvalidAttestation();
    error InvalidPayment();
    error DuplicateRequest();

    event ProtocolSet(address indexed intake, address indexed imd, bytes32 action);
    event PanelSet(uint16 panelSize, uint16 quorum, uint32 validForSeconds);
    event Asked(
        uint256 indexed id, address indexed asker, bytes32 indexed intakeRequestId, string question, uint256 price
    );
    event Answered(
        uint256 indexed id, bytes32 indexed oracleRequestId, bool answer, uint16 agreed, uint16 quorum, uint16 panelSize
    );
    event Unanswered(uint256 indexed id);

    uint256 public constant QUESTION_CHAIN_ID = 4663;
    uint256 public constant ANSWER_TIMEOUT = 1 days;
    address public immutable owner;
    IIntake public intake;
    IERC20 public imd;
    bytes32 public action;
    uint16 public panelSize;
    uint16 public quorum;
    uint32 public validForSeconds;
    uint256 public count;
    /// @notice ID most recently answered (delivery order), or 0 before the first answer.
    uint256 public latestAnswered;
    mapping(uint256 => Question) private _questions;
    mapping(address => mapping(bytes32 => uint256)) public questionIdFor;

    constructor(
        address owner_,
        address intake_,
        address imd_,
        bytes32 action_,
        address signer_,
        uint16 panelSize_,
        uint16 quorum_,
        uint32 validForSeconds_
    ) OracleAttestationConsumer(signer_) {
        if (owner_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
        _setProtocol(intake_, imd_, action_);
        _setPanel(panelSize_, quorum_, validForSeconds_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function ask(string calldata text) external nonReentrant returns (uint256 id) {
        string memory escaped = QuestionText.escape(text);
        id = ++count;
        Question storage q = _questions[id];
        q.asker = msg.sender;
        q.text = text;
        q.askedAt = uint64(block.timestamp);
        q.intake = address(intake);
        q.requestedPanelSize = panelSize;
        q.requestedQuorum = quorum;
        q.requestedValidity = validForSeconds;
        bytes memory body = bytes(
            string.concat(
                '{"v":1,"question":"',
                escaped,
                '","chainId":4663,"window":{"hours":1},"answerType":"bool","evidence":"panel","panelSize":',
                Strings.toString(panelSize),
                ',"quorum":',
                Strings.toString(quorum),
                ',"validForSeconds":',
                Strings.toString(validForSeconds),
                "}"
            )
        );
        IERC20 token = imd;
        uint256 price = intake.priceOf(action, address(token));
        if (price == 0) revert InvalidPayment();
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), price);
        if (token.balanceOf(address(this)) != balanceBefore + price) revert InvalidPayment();
        token.forceApprove(q.intake, price);
        bytes32 requestId = IIntake(q.intake)
            .request(action, body, IIntake.Callback(address(this), this.onOracleResult.selector), address(token), price);
        token.forceApprove(q.intake, 0);
        if (token.balanceOf(address(this)) != balanceBefore) revert InvalidPayment();
        if (questionIdFor[q.intake][requestId] != 0) revert DuplicateRequest();
        q.intakeRequestId = requestId;
        questionIdFor[q.intake][requestId] = id;
        emit Asked(id, msg.sender, requestId, text, price);
    }

    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 id = questionIdFor[msg.sender][requestId];
        if (id == 0) {
            if (msg.sender != address(intake)) revert OnlyIntake();
            revert UnknownRequest();
        }
        Question storage q = _questions[id];
        if (q.status != Status.Pending) revert NotPending();
        if (block.timestamp >= uint256(q.askedAt) + ANSWER_TIMEOUT) revert DeadlinePassed();
        _verifyAttestation(a, signature);
        if (
            a.chainId != QUESTION_CHAIN_ID || a.panelSize < q.requestedPanelSize || a.panelSize > 300
                || a.quorum < q.requestedQuorum || a.quorum > a.panelSize || a.agreed < a.quorum
                || a.agreed > a.panelSize || a.fromBlock > a.toBlock || a.issuedAt < q.askedAt
                || a.expiresAt < a.issuedAt || uint256(a.expiresAt) - a.issuedAt > q.requestedValidity
        ) revert InvalidAttestation();
        if (a.answer.length != 32) revert InvalidAttestation();
        bool answer = decodeBool(a);
        _consume(a.requestId);
        q.status = Status.Answered;
        q.answer = answer;
        q.agreed = a.agreed;
        q.quorum = a.quorum;
        q.panelSize = a.panelSize;
        q.answeredAt = uint64(block.timestamp);
        latestAnswered = id;
        emit Answered(id, a.requestId, answer, a.agreed, a.quorum, a.panelSize);
    }

    function markUnanswered(uint256 id) external nonReentrant {
        Question storage q = _question(id);
        if (q.status != Status.Pending) revert NotPending();
        if (block.timestamp < uint256(q.askedAt) + ANSWER_TIMEOUT) revert TooEarly();
        q.status = Status.Unanswered;
        emit Unanswered(id);
    }

    function question(uint256 id)
        external
        view
        returns (
            address asker,
            string memory text,
            Status status,
            bool answer,
            uint16 agreed,
            uint16 quorum_,
            uint16 panelSize_,
            uint64 askedAt,
            uint64 answeredAt
        )
    {
        Question storage q = _question(id);
        return (q.asker, q.text, q.status, q.answer, q.agreed, q.quorum, q.panelSize, q.askedAt, q.answeredAt);
    }

    function requestDetails(uint256 id)
        external
        view
        returns (
            address requestIntake,
            bytes32 intakeRequestId,
            uint16 requestedPanelSize,
            uint16 requestedQuorum,
            uint32 requestedValidity
        )
    {
        Question storage q = _question(id);
        return (q.intake, q.intakeRequestId, q.requestedPanelSize, q.requestedQuorum, q.requestedValidity);
    }

    function setProtocol(address intake_, address imd_, bytes32 action_) external onlyOwner nonReentrant {
        _setProtocol(intake_, imd_, action_);
    }

    function setSigner(address signer_) external onlyOwner nonReentrant {
        _setOracleSigner(signer_);
    }

    function setPanel(uint16 panelSize_, uint16 quorum_, uint32 validForSeconds_) external onlyOwner nonReentrant {
        _setPanel(panelSize_, quorum_, validForSeconds_);
    }

    function _setProtocol(address intake_, address imd_, bytes32 action_) private {
        if (intake_ == address(0) || imd_ == address(0) || action_ == bytes32(0)) revert InvalidConfiguration();
        intake = IIntake(intake_);
        imd = IERC20(imd_);
        action = action_;
        emit ProtocolSet(intake_, imd_, action_);
    }

    function _setPanel(uint16 panelSize_, uint16 quorum_, uint32 validForSeconds_) private {
        if (
            panelSize_ < 2 || panelSize_ > 300 || quorum_ < 2 || quorum_ > panelSize_ || validForSeconds_ < 60
                || validForSeconds_ > 30 days
        ) revert InvalidConfiguration();
        panelSize = panelSize_;
        quorum = quorum_;
        validForSeconds = validForSeconds_;
        emit PanelSet(panelSize_, quorum_, validForSeconds_);
    }

    function _question(uint256 id) private view returns (Question storage q) {
        if (id == 0 || id > count) revert UnknownQuestion();
        q = _questions[id];
    }
}
