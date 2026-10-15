// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Lossless JSON string encoding. Validation excludes malformed UTF-8, not player instructions.
library MessageJson {
    error InvalidUTF8();
    error MalformedEscape();

    /// @return escapedLength Upper bound of bytes inside JSON quotes; exact when no escape is needed.
    /// @dev Every control character is counted as a six-byte `\u00XX` escape even where `escape`
    ///      emits the two-byte short form, so the count is only exact for text that needs no escape.
    function validate(bytes calldata text) internal pure returns (uint256 escapedLength) {
        bool valid = true;
        // A bounded calldata scan avoids allocating/copying player text or repeated array bounds checks.
        // Lead bytes, continuation bytes, shortest form, surrogates and U+10FFFF are all checked.
        assembly ("memory-safe") {
            function equalByteMask(word, repeatedByte) -> result {
                let lowBits := 0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f
                let x := xor(word, repeatedByte)
                result := not(or(or(add(and(x, lowBits), lowBits), x), lowBits))
            }
            function countHighBits(mask) -> count {
                count := byte(
                    0,
                    mul(shr(7, mask), 0x0101010101010101010101010101010101010101010101010101010101010101)
                )
            }
            let cursor := text.offset
            let end := add(cursor, text.length)
            let nextWord := cursor
            for {} lt(cursor, end) {} {
                // Process 32 ASCII bytes together. Each per-byte sum stays below 256, so no
                // carry crosses byte boundaries. The final byte of the product is a popcount.
                if iszero(lt(cursor, nextWord)) {
                    nextWord := add(cursor, 32)
                    if iszero(gt(nextWord, end)) {
                        let word := calldataload(cursor)
                        let highBits := 0x8080808080808080808080808080808080808080808080808080808080808080
                        if iszero(and(word, highBits)) {
                            let controls :=
                                and(
                                    not(
                                        add(
                                            word,
                                            0x6060606060606060606060606060606060606060606060606060606060606060
                                        )
                                    ),
                                    highBits
                                )
                            let quotes :=
                                equalByteMask(
                                    word,
                                    0x2222222222222222222222222222222222222222222222222222222222222222
                                )
                            let slashes :=
                                equalByteMask(
                                    word,
                                    0x5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c
                                )
                            escapedLength := add(
                                escapedLength,
                                add(
                                    32,
                                    add(mul(5, countHighBits(controls)), countHighBits(or(quotes, slashes)))
                                )
                            )
                            cursor := add(cursor, 32)
                            continue
                        }
                    }
                }
                let c := byte(0, calldataload(cursor))
                switch lt(c, 0x80)
                case 1 {
                    // Mixed text often has long ASCII runs inside a word containing a Unicode scalar.
                    // An eight-byte fast path keeps those runs from falling back to a bytewise scan.
                    if iszero(gt(add(cursor, 8), end)) {
                        let topEight := 0xffffffffffffffff000000000000000000000000000000000000000000000000
                        let highBits := 0x8080808080808080000000000000000000000000000000000000000000000000
                        let word := and(calldataload(cursor), topEight)
                        if iszero(and(word, highBits)) {
                            let controls :=
                                and(
                                    not(
                                        add(
                                            word,
                                            0x6060606060606060000000000000000000000000000000000000000000000000
                                        )
                                    ),
                                    highBits
                                )
                            let quotes :=
                                and(
                                    equalByteMask(
                                        word,
                                        0x2222222222222222222222222222222222222222222222222222222222222222
                                    ),
                                    topEight
                                )
                            let slashes :=
                                and(
                                    equalByteMask(
                                        word,
                                        0x5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c
                                    ),
                                    topEight
                                )
                            escapedLength := add(
                                escapedLength,
                                add(
                                    8,
                                    add(mul(5, countHighBits(controls)), countHighBits(or(quotes, slashes)))
                                )
                            )
                            cursor := add(cursor, 8)
                            continue
                        }
                    }
                    let cost := 1
                    if or(eq(c, 34), eq(c, 92)) { cost := 2 }
                    if lt(c, 32) { cost := 6 }
                    escapedLength := add(escapedLength, cost)
                    cursor := add(cursor, 1)
                }
                default {
                    // Two-byte scalars have no surrogate/range special cases beyond their lead byte.
                    if lt(c, 0xe0) {
                        if or(lt(c, 0xc2), iszero(lt(add(cursor, 1), end))) {
                            valid := 0
                            break
                        }
                        if iszero(eq(and(byte(0, calldataload(add(cursor, 1))), 0xc0), 0x80)) {
                            valid := 0
                            break
                        }
                        escapedLength := add(escapedLength, 2)
                        cursor := add(cursor, 2)
                        continue
                    }
                    let word := calldataload(cursor)
                    let second := byte(1, word)
                    switch lt(c, 0xf0)
                    case 1 {
                        if gt(add(cursor, 3), end) {
                            valid := 0
                            break
                        }
                        if iszero(eq(and(shr(232, word), 0xc0c0), 0x8080)) {
                            valid := 0
                            break
                        }
                        if or(and(eq(c, 0xe0), lt(second, 0xa0)), and(eq(c, 0xed), gt(second, 0x9f))) {
                            valid := 0
                            break
                        }
                        escapedLength := add(escapedLength, 3)
                        cursor := add(cursor, 3)
                    }
                    default {
                        if or(gt(c, 0xf4), gt(add(cursor, 4), end)) {
                            valid := 0
                            break
                        }
                        if iszero(eq(and(shr(224, word), 0xc0c0c0), 0x808080)) {
                            valid := 0
                            break
                        }
                        if or(and(eq(c, 0xf0), lt(second, 0x90)), and(eq(c, 0xf4), gt(second, 0x8f))) {
                            valid := 0
                            break
                        }
                        escapedLength := add(escapedLength, 4)
                        cursor := add(cursor, 4)
                    }
                }
            }
        }
        if (!valid) revert InvalidUTF8();
    }

    /// @notice Validates UTF-8 and returns the JSON string body (without surrounding quotes).
    /// @dev `"` and `\` are backslash-escaped, \b \t \n \f \r use their short forms and every other
    ///      control character becomes `\u00XX`. Text that needs no escape is copied verbatim.
    function escape(bytes calldata text) internal pure returns (bytes memory out) {
        uint256 bound = validate(text);
        if (bound == text.length) return text;
        out = new bytes(bound);
        assembly ("memory-safe") {
            let hexTable := 0x3031323334353637383961626364656600000000000000000000000000000000
            let dst := add(out, 32)
            let cursor := dst
            let src := text.offset
            let end := add(src, text.length)
            for {} lt(src, end) { src := add(src, 1) } {
                let c := byte(0, calldataload(src))
                switch lt(c, 0x20)
                case 1 {
                    let short := 0
                    switch c
                    case 0x08 { short := 0x62 }
                    case 0x09 { short := 0x74 }
                    case 0x0a { short := 0x6e }
                    case 0x0c { short := 0x66 }
                    case 0x0d { short := 0x72 }
                    mstore8(cursor, 0x5c)
                    switch short
                    case 0 {
                        mstore8(add(cursor, 1), 0x75)
                        mstore8(add(cursor, 2), 0x30)
                        mstore8(add(cursor, 3), 0x30)
                        mstore8(add(cursor, 4), byte(shr(4, c), hexTable))
                        mstore8(add(cursor, 5), byte(and(c, 15), hexTable))
                        cursor := add(cursor, 6)
                    }
                    default {
                        mstore8(add(cursor, 1), short)
                        cursor := add(cursor, 2)
                    }
                }
                default {
                    if or(eq(c, 0x22), eq(c, 0x5c)) {
                        mstore8(cursor, 0x5c)
                        cursor := add(cursor, 1)
                    }
                    mstore8(cursor, c)
                    cursor := add(cursor, 1)
                }
            }
            mstore(out, sub(cursor, dst))
        }
    }

    /// @notice Inverse of `escape` for the sequences it emits. A view helper, not gas-critical.
    function unescape(bytes memory text) internal pure returns (bytes memory out) {
        out = new bytes(text.length);
        uint256 n;
        for (uint256 i; i < text.length; ++i) {
            uint8 c = uint8(text[i]);
            if (c != 0x5c) {
                out[n++] = bytes1(c);
                continue;
            }
            if (i + 1 >= text.length) revert MalformedEscape();
            uint8 e = uint8(text[++i]);
            if (e == 0x75) {
                if (i + 4 >= text.length) revert MalformedEscape();
                uint256 value;
                for (uint256 j = 1; j <= 4; ++j) {
                    value = value * 16 + _hexValue(uint8(text[i + j]));
                }
                if (value > 0xff) revert MalformedEscape();
                out[n++] = bytes1(uint8(value));
                i += 4;
            } else if (e == 0x62) {
                out[n++] = 0x08;
            } else if (e == 0x74) {
                out[n++] = 0x09;
            } else if (e == 0x6e) {
                out[n++] = 0x0a;
            } else if (e == 0x66) {
                out[n++] = 0x0c;
            } else if (e == 0x72) {
                out[n++] = 0x0d;
            } else if (e == 0x22 || e == 0x5c) {
                out[n++] = bytes1(e);
            } else {
                revert MalformedEscape();
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _hexValue(uint8 c) private pure returns (uint256) {
        if (c >= 0x30 && c <= 0x39) return c - 0x30;
        if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
        revert MalformedEscape();
    }
}
