// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import "./BaseRestorableSalary.sol";

interface OurDAO {
    function checkAllowedRestoreAccount(address oldAccount_, address newAccount_) external;
}

contract RestorableSalary is BaseRestorableSalary {
    OurDAO dao;

    constructor(OurDAO _dao, string memory uri_) BaseRestorableSalary(uri_) {
        dao = _dao;
    }

    function setDAO(OurDAO _dao) public onlyDAO {
        dao = _dao;
    }

    /// Set the token URI.
    /// This function is not in its proper place of inheritance, but here we have DAO, so we can just use it.
    function setURI(string memory newuri) public onlyDAO {
        _setURI(newuri);
    }

    function checkAllowedRestoreAccount(address oldAccount_, address newAccount_) public virtual override {
        dao.checkAllowedRestoreAccount(oldAccount_, newAccount_);
    }

    modifier onlyDAO() {
        require(msg.sender == address(dao)  , "Only DAO can do.");
        _;
    }
}
