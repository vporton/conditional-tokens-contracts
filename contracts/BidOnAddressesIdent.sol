pragma solidity ^0.5.1;
import "./BidOnAddresses.sol";

// https://brightid.gitbook.io
// https://docs.google.com/document/d/16-gqjfJLz7WSYVDHVQSFKK3Mj0GFWetxdgE9nQuMS9o/edit#heading=h.s5d6g1yzfjl0

/// BidOnAddresses with BrightID identity
contract BidOnAddressesIdent is BidOnAddresses {
    // TODO: Nontranferrable token with its rent given to alive person tradeable and redeemable.
    // TODO: Also combine both variants.
    // TODO: Account recovery.
    // TODO: MACI by Vitalik
    // TODO: Allow change 100 years to something other by voting?
    // TODO: Microsoft Azure to run a BrightID node till we vote to make it decentralized.
    // TODO: Oracle based (with quadratic upgradeable voting) recovery of lost accounts.
}
