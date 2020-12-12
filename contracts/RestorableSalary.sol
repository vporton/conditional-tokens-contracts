// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import "./BaseRestorableSalary.sol";

interface OurDAO {
    function checkAllowedRestoreAccount(address oldAccount_, address newAccount_) external;
}

contract RestorableSalary is BaseRestorableSalary {
    function checkAllowedRestoreAccount(address oldAccount_, address newAccount_) public virtual override {
        dao.checkAllowedRestoreAccount(oldAccount_, newAccount_);
    }
}
