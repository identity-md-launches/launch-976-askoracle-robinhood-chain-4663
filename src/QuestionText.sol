// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Strict UTF-8, excluding Unicode C0/C1 controls; JSON quoting preserves the user's question.
library QuestionText {
    error InvalidQuestion();

    function escape(string calldata question) internal pure returns (string memory) {
        bytes calldata raw = bytes(question);
        if (raw.length == 0 || raw.length > 500) revert InvalidQuestion();
        for (uint256 i; i < raw.length;) {
            uint8 lead = uint8(raw[i]);
            uint256 width;
            uint256 point;
            uint256 minimum;
            if (lead < 0x80) {
                width = 1;
                point = lead;
            } else if (lead >= 0xc2 && lead <= 0xdf) {
                width = 2;
                point = lead & 0x1f;
                minimum = 0x80;
            } else if (lead >= 0xe0 && lead <= 0xef) {
                width = 3;
                point = lead & 0x0f;
                minimum = 0x800;
            } else if (lead >= 0xf0 && lead <= 0xf4) {
                width = 4;
                point = lead & 0x07;
                minimum = 0x10000;
            } else {
                revert InvalidQuestion();
            }
            if (i + width > raw.length) revert InvalidQuestion();
            for (uint256 j = 1; j < width; ++j) {
                uint8 next = uint8(raw[i + j]);
                if (next < 0x80 || next > 0xbf) revert InvalidQuestion();
                point = (point << 6) | (next & 0x3f);
            }
            if (
                point < minimum || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff) || point < 0x20
                    || (point >= 0x7f && point <= 0x9f)
            ) revert InvalidQuestion();
            i += width;
        }
        bytes memory quoted = new bytes(raw.length * 2);
        uint256 length;
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == 0x22 || raw[i] == 0x5c) quoted[length++] = 0x5c;
            quoted[length++] = raw[i];
        }
        assembly ("memory-safe") {
            mstore(quoted, length)
        }
        return string(quoted);
    }
}
