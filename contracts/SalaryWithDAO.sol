// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import "./BaseRestorableSalary.sol";

interface OurDAO {
    /// Revert if the person is dead.
    /// @param account the current account (not the original account)
    /// TODO: Maybe better to use original account as the argument?
    function checkPersonDead(address account) external;

    function checkAllowedRestoreAccount(address oldAccount_, address newAccount_) external;
}

contract SalaryWithDAO is BaseRestorableSalary {
    using ABDKMath64x64 for int128;

    OurDAO public dao;

    int128 public daoShare = int128(0).div(1); // zero by default

    constructor(OurDAO _dao, string memory uri_) BaseRestorableSalary(uri_) {
        dao = _dao;
    }

    function setDAO(OurDAO _dao) public onlyDAO {
        dao = _dao;
    }

    /// Set the multiplier of tokens given to the DAO
    /// @param share is an 64x64 fraction. We don't check if it is above zero, because `.mulu()` will just fail in this case.
    function setDaoShare(int128 share) public onlyDAO {
        daoShare = share;
    }

    /// Set the token URI.
    function setURI(string memory newuri) public onlyDAO {
        _setURI(newuri);
    }

    function _mintToCustomer(uint256 conditionalTokenId, uint256 amount, bytes calldata data) internal virtual override {
        dao.checkPersonDead(msg.sender);
        super._mintToCustomer(conditionalTokenId, amount, data);
        if (daoShare != int128(0).div(1)) { // Save gas.
            _mint(address(dao), conditionalTokenId, daoShare.mulu(amount), data);
        }
    }

    function checkAllowedRestoreAccount(address oldAccount_, address newAccount_) public virtual override {
        dao.checkAllowedRestoreAccount(oldAccount_, newAccount_);
    }

    modifier onlyDAO() {
        require(msg.sender == address(dao), "Only DAO can do.");
        _;
    }
}
