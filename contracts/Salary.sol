// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import "./BaseBidOnAddresses.sol";

contract Salary is BaseBidOnAddresses {
    event CustomerRegistered(
        address customer,
        uint64 marketId,
        bytes data
    );

    event SalaryMinted(
        address customer,
        uint64 marketId,
        uint256 amount,
        bytes data
    );

    // Mapping from original address to last salary block time.
    mapping(address => uint) lastSalaryDates;

    constructor(string memory uri_) BaseBidOnAddresses(uri_) {
    }

    /// Anyone can register himself.
    /// Can be called both before or after the oracle finish. However registering after the finish is useless.
    function registerCustomer(uint64 marketId, bytes calldata data) external {
        uint256 conditionalTokenId = _conditionalTokenId(marketId, msg.sender);
        address orig = originalAddress(msg.sender);
        require(lastSalaryDates[orig] == 0, "You are already registered.");
        lastSalaryDates[orig] = block.timestamp;
        emit CustomerRegistered(msg.sender, marketId, data);
    }

    function mintSalary(uint64 marketId, bytes calldata data) external {
        address orig = originalAddress(msg.sender);
        uint lastSalaryDate = lastSalaryDates[orig];
        require(lastSalaryDate != 0, "You are not registered.");
        uint256 conditionalTokenId = _conditionalTokenId(marketId, msg.sender);
        uint256 amount = (lastSalaryDate - block.timestamp) * 10**18; // one token per second
        _mint(msg.sender, conditionalTokenId, amount, data);
        lastSalaryDates[orig] = block.timestamp;
        emit SalaryMinted(msg.sender, marketId, amount, data);
    }

    // FIXME: conditon address or condtional token?
    function marketTotal(address /*condition*/) public virtual override view returns (uint256) {
        return INITIAL_CUSTOMER_BALANCE;
    }
}
