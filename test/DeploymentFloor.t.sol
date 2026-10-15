// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BegVaultBase} from "./BegVaultBase.sol";
import {BegVault} from "../src/BegVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract DeploymentFloorTest is BegVaultBase {
    function testRuntimeFitsAndHasNoEscapeOpcodes() public view {
        _checkCode(address(token).code);
        _checkCode(address(vault).code);
    }

    function testApplicationConstructorPreservesFactorySupply() public {
        LaunchToken launchToken = new LaunchToken();
        uint256 supply = launchToken.totalSupply();
        BegVault app = new BegVault(
            address(launchToken), TEAM, address(intake), address(imd), vm.addr(SIGNER_KEY), PRICE
        );
        assertEq(launchToken.balanceOf(address(this)), supply);
        assertEq(launchToken.balanceOf(address(app)), 0);
        assertEq(launchToken.totalSupply(), 1_000_000_000 ether);
    }

    function testMessagesLiveInNonceDerivedDataContractsNotVaultStorage() public {
        bytes memory text = new bytes(280);
        for (uint256 i; i < text.length; ++i) {
            text[i] = 0x61;
        }
        vm.record();
        vault.attempt{value: PRICE}(string(text));
        (, bytes32[] memory slots) = vm.accesses(address(vault));
        bytes32 fullWord = 0x6161616161616161616161616161616161616161616161616161616161616161;
        for (uint256 i; i < slots.length; ++i) {
            bytes32 value = vm.load(address(vault), slots[i]);
            assertTrue(value != fullWord && value != (fullWord & bytes32(type(uint256).max << 64)));
        }
        address pointer = vault.messagePointer(1, 0);
        assertEq(pointer, vm.computeCreateAddress(address(vault), 1));
        assertEq(pointer.code, bytes.concat(hex"00", bytes2(uint16(280)), text));
        assertEq(vault.getAttempt(1).message, string(text));
        assertEq(vault.autoClosed(), 0);
        string memory raw = "A second entry with \"quotes\" and a\nnewline";
        string memory escaped = "A second entry with \\\"quotes\\\" and a\\nnewline";
        _attempt(_player(2), raw);
        address second = vault.messagePointer(1, 1);
        assertEq(second, vm.computeCreateAddress(address(vault), 2));
        assertEq(second.code, bytes.concat(hex"00", bytes2(uint16(bytes(escaped).length)), bytes(escaped)));
        assertEq(vault.getAttempt(2).message, raw);
        _checkCode(pointer.code);
    }

    function testPointerDerivationMatchesCreateAddressesAcrossRlpLengthBoundaries() public view {
        uint256[9] memory nonces = [uint256(1), 0x7f, 0x80, 0xff, 0x100, 0xffff, 0x10000, 0xffffff, 0x1000000];
        for (uint256 i; i < nonces.length; ++i) {
            // Batch 1 has first attempt id 0 and skew 0 before its first entry, so the index is the nonce.
            assertEq(vault.messagePointer(1, nonces[i]), vm.computeCreateAddress(address(vault), nonces[i]));
        }
    }

    function _checkCode(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden escape opcode");
        }
    }
}
