// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract MockIntake is IIntake {
    using SafeERC20 for IERC20;

    uint256 public price = 0.5 ether;
    address public immutable recipient;
    bytes public lastBody;
    bytes32 public lastAction;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public allowanceAtRequest;
    uint256 public nonce;
    bytes32 public lastRequestId;
    mapping(bytes32 => Callback) public callbacks;
    bool public fail;
    bool public skipPull;
    bool public duplicate;
    address public hook;
    bytes public hookData;
    bool public hookSucceeded;

    constructor(address recipient_) {
        recipient = recipient_;
    }

    function setPrice(uint256 value) external {
        price = value;
    }

    function setBehavior(bool fail_, bool skipPull_, bool duplicate_) external {
        fail = fail_;
        skipPull = skipPull_;
        duplicate = duplicate_;
    }

    function setHook(address target, bytes calldata data) external {
        hook = target;
        hookData = data;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(!fail, "intake failed");
        require(msg.value == 0 && amount == price, "wrong price");
        lastBody = body;
        lastAction = action;
        lastAsset = asset;
        lastAmount = amount;
        allowanceAtRequest = IERC20(asset).allowance(msg.sender, address(this));
        if (!skipPull) IERC20(asset).safeTransferFrom(msg.sender, recipient, amount);
        if (hook != address(0)) (hookSucceeded,) = hook.call(hookData);
        requestId = duplicate ? lastRequestId : keccak256(abi.encode(address(this), ++nonce));
        lastRequestId = requestId;
        callbacks[requestId] = callback;
    }

    function deliver(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (uint256 gasUsed)
    {
        Callback memory callback = callbacks[requestId];
        bytes memory data = abi.encodeWithSelector(callback.selector, requestId, a, signature);
        uint256 start = gasleft();
        (bool ok, bytes memory reason) = callback.target.call{gas: 200_000}(data);
        gasUsed = start - gasleft();
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }
}
