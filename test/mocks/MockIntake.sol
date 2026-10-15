// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("Mock IMD", "mIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockIntake is IIntake {
    uint256 public price = 0.5 ether;
    uint256 public requests;
    bool public rejectRequests;
    bool public recordBody = true;
    bool public duplicateId;
    bytes public lastBody;
    bytes32 public lastAction;
    address public lastAsset;
    uint256 public lastAmount;
    mapping(bytes32 => Callback) public callbacks;

    function setPrice(uint256 value) external {
        price = value;
    }

    function setReject(bool value) external {
        rejectRequests = value;
    }

    function setRecordBody(bool value) external {
        recordBody = value;
    }

    function setDuplicateId(bool value) external {
        duplicateId = value;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        require(!rejectRequests, "intake unavailable");
        require(action == bytes32("oracle.request@oracle-1"), "action");
        require(msg.value == 0 && asset != address(0) && amount == price, "payment");
        require(body.length <= 16_384, "body too large");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "pull");
        ++requests;
        requestId = keccak256(abi.encode(duplicateId ? 1 : requests));
        callbacks[requestId] = callback;
        if (recordBody) lastBody = body;
        lastAction = action;
        lastAsset = asset;
        lastAmount = amount;
    }

    /// @dev Mirrors the production callback's hard gas limit, without bubbling its revert.
    function deliver(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok, bytes memory result)
    {
        Callback memory callback = callbacks[requestId];
        (ok, result) = callback.target.call{gas: 200_000}(
            abi.encodeWithSelector(callback.selector, requestId, a, signature)
        );
    }
}
