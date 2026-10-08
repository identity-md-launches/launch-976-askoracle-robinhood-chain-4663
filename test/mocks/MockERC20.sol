// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    bool public returnFalse;
    bool public noReturn;
    bool public takeFee;
    bool public requireZeroApproval;
    address public hook;
    bytes public hookData;
    bool public hookSucceeded;

    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBehavior(bool false_, bool noReturn_, bool fee_, bool zeroApproval_) external {
        returnFalse = false_;
        noReturn = noReturn_;
        takeFee = fee_;
        requireZeroApproval = zeroApproval_;
    }

    function setHook(address target, bytes calldata data) external {
        hook = target;
        hookData = data;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        super.transferFrom(from, to, value);
        if (takeFee && value > 0) _burn(to, 1);
        if (hook != address(0)) (hookSucceeded,) = hook.call(hookData);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        if (requireZeroApproval && value != 0 && allowance(msg.sender, spender) != 0) return false;
        super.approve(spender, value);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}
