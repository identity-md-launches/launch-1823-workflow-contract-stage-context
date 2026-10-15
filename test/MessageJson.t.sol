// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MessageJson} from "../src/libraries/MessageJson.sol";

contract MessageJsonHarness {
    function validate(bytes calldata text) external pure returns (uint256) {
        return MessageJson.validate(text);
    }

    function escape(bytes calldata text) external pure returns (bytes memory) {
        return MessageJson.escape(text);
    }

    function unescape(bytes memory text) external pure returns (bytes memory) {
        return MessageJson.unescape(text);
    }

    /// @dev Quoted form, as the vault writes it into a definition value.
    function quote(bytes calldata text) external pure returns (bytes memory) {
        return bytes.concat('"', MessageJson.escape(text), '"');
    }
}

contract MessageJsonTest is Test {
    MessageJsonHarness harness = new MessageJsonHarness();

    function testFuzzUTF8AcceptanceMatchesCodepointDecoder(bytes memory input) public view {
        if (input.length > 280) {
            assembly ("memory-safe") { mstore(input, 280) }
        }
        (bool expectedValid, uint256 expectedLength) = _reference(input);
        try harness.validate(input) returns (uint256 length) {
            assertTrue(expectedValid);
            assertEq(length, expectedLength);
        } catch {
            assertFalse(expectedValid);
        }
    }

    function testFuzzAsciiMaskCountsEveryEscapedByte(bytes32 entropy, uint16 rawLength) public view {
        uint256 length = bound(rawLength, 1, 280);
        bytes memory input = new bytes(length);
        uint256 expected;
        for (uint256 i; i < length; ++i) {
            uint8 c = uint8(entropy[i % 32]) & 127;
            input[i] = bytes1(c);
            expected += c < 32 ? 6 : c == 34 || c == 92 ? 2 : 1;
        }
        assertEq(harness.validate(input), expected);
        bytes memory quoted = harness.quote(input);
        assertLe(quoted.length, expected + 2);
        assertEq(harness.unescape(harness.escape(input)), input);
        assertEq(
            vm.parseJsonString(string(bytes.concat(bytes('{"text":'), quoted, bytes("}"))), ".text"),
            string(input)
        );
    }

    function testEveryAsciiByteAcrossWordBoundaries() public view {
        for (uint256 c; c < 128; ++c) {
            bytes memory input = new bytes(280);
            for (uint256 i; i < 280; ++i) {
                input[i] = bytes1(uint8(c));
            }
            uint256 perByte = c < 32 ? 6 : c == 34 || c == 92 ? 2 : 1;
            assertEq(harness.validate(input), 280 * perByte);
            bool shortEscape = c == 8 || c == 9 || c == 10 || c == 12 || c == 13;
            assertEq(harness.quote(input).length, 280 * (shortEscape ? 2 : perByte) + 2);
            assertEq(harness.unescape(harness.escape(input)), input);
            if (c == 10) assertEq(harness.escape(input)[1], "n");
        }
    }

    function testUnicodeBoundariesAndInvalidSequences() public view {
        bytes memory valid = hex"007fc280dfbfe0a080ed9fbfee8080efbfbff0908080f48fbfbf";
        assertEq(harness.validate(valid), valid.length + 5);
        bytes[11] memory invalid = [
            bytes(hex"80"),
            hex"c0af",
            hex"c1bf",
            hex"c2",
            hex"e08080",
            hex"eda080",
            hex"f0808080",
            hex"f4908080",
            hex"f5808080",
            hex"ff",
            hex"e282"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            (bool ok,) = address(harness).staticcall(abi.encodeCall(harness.validate, (invalid[i])));
            assertFalse(ok);
        }
    }

    function testFuzzValidUnicodeScalarsRoundTrip(uint32 first, uint32 second, uint32 third) public view {
        bytes memory group = bytes.concat(_scalar(first), _scalar(second), _scalar(third), bytes('"\\\n'));
        bytes memory input;
        while (input.length + group.length <= 280) input = bytes.concat(input, group);
        (bool valid, uint256 expectedLength) = _reference(input);
        assertTrue(valid);
        assertEq(harness.validate(input), expectedLength);
        bytes memory quoted = harness.quote(input);
        assertLe(quoted.length, expectedLength + 2); // short escapes may shrink it
        assertEq(harness.unescape(harness.escape(input)), input);
        string memory body = string(bytes.concat(bytes('{"text":'), quoted, bytes("}")));
        assertEq(vm.parseJsonString(body, ".text"), string(input));
    }

    function _scalar(uint32 raw) private pure returns (bytes memory) {
        uint256 c = uint256(raw) % 0x110000;
        if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
        if (c < 0x80) return abi.encodePacked(uint8(c));
        if (c < 0x800) return abi.encodePacked(uint8(0xc0 | (c >> 6)), uint8(0x80 | (c & 63)));
        if (c < 0x10000) {
            return
                abi.encodePacked(
                    uint8(0xe0 | (c >> 12)), uint8(0x80 | ((c >> 6) & 63)), uint8(0x80 | (c & 63))
                );
        }
        return abi.encodePacked(
            uint8(0xf0 | (c >> 18)),
            uint8(0x80 | ((c >> 12) & 63)),
            uint8(0x80 | ((c >> 6) & 63)),
            uint8(0x80 | (c & 63))
        );
    }

    function _reference(bytes memory input) private pure returns (bool valid, uint256 escapedLength) {
        uint256 i;
        while (i < input.length) {
            uint256 c = uint8(input[i++]);
            if (c < 128) {
                escapedLength += c < 32 ? 6 : c == 34 || c == 92 ? 2 : 1;
                continue;
            }
            uint256 n;
            uint256 cp;
            uint256 min;
            if (c & 0xe0 == 0xc0) {
                n = 2;
                cp = c & 31;
                min = 128;
            } else if (c & 0xf0 == 0xe0) {
                n = 3;
                cp = c & 15;
                min = 2048;
            } else if (c & 0xf8 == 0xf0) {
                n = 4;
                cp = c & 7;
                min = 65536;
            } else {
                return (false, 0);
            }
            if (input.length - i < n - 1) return (false, 0);
            for (uint256 j = 1; j < n; ++j) {
                uint256 next = uint8(input[i++]);
                if (next & 0xc0 != 0x80) return (false, 0);
                cp = (cp << 6) | (next & 63);
            }
            if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return (false, 0);
            escapedLength += n;
        }
        return (true, escapedLength);
    }
}
