// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import "./BidOnAddresses.sol";

contract SecondLevelBidOnAddresses is BidOnAddresses {
    BaseBidOnAddresses public parent;
    
    constructor(BaseBidOnAddresses parent_, string memory uri_) BidOnAddresses(uri_) {
        parent = parent_;
    }

    /// For each collateral needs to be called only once, called again it reverts.
    /// Anyone can call this.
    /// TODO: This becomes not needed at all, if we allow anyone to withdraw for others.
    function withdrawParentCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 parentMarketId,
        uint64 parentOracleId,
        address parentCondition,
        bytes calldata data) public
    {
        parent.withdrawCollateral(collateralContractAddress, collateralTokenId, parentMarketId, parentOracleId, msg.sender, parentCondition, data);
    }
}
