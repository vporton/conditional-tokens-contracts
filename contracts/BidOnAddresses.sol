// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.1;
import "@openzeppelin/contracts/math/SafeMath.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import { IERC1155 } from "./ERC1155/IERC1155.sol";
import { IERC1155TokenReceiver } from "./ERC1155/IERC1155TokenReceiver.sol";
import { ERC1155WithMappedAddressesAndTotals } from "./ERC1155/ERC1155WithMappedAddressesAndTotals.sol";

// TODO: Extract bequesting capabilities into a separate contract.
// TODO: Allow to override the date of allowed withdrawal of bequested funds (multiple dates per single staker?)
// TODO: Also the ability to transfer staked (and donated?) funds to other market/oracle (in conjunction with changing the date)?

/// @title Bidding on Ethereum addresses
/// @author Victor Porton
/// @notice Not audited, not enough tested.
/// This allows anyone claim 1000 conditional tokens in order for him to transfer money from the future.
/// See `docs/future-money.rst`.
///
/// We have three kinds of ERC-1155 token ID
/// - a combination of market ID, collateral address, and customer address (conditional tokens)
/// - a combination of TOKEN_STAKED and collateral address (staked collateral tokens)
/// - a combination of TOKEN_SUMMARY and collateral address (staked + staked collateral tokens)
///
/// In functions of this contact `condition` is always a customer's original address.
///
/// We receive funds in ERC-1155, see also https://github.com/vporton/wrap-tokens
contract BidOnAddresses is ERC1155WithMappedAddressesAndTotals, IERC1155TokenReceiver {
    using ABDKMath64x64 for int128;
    using SafeMath for uint256;

    enum TokenKind { TOKEN_CONDITIONAL, TOKEN_DONATED, TOKEN_STAKED }

    uint constant INITIAL_CUSTOMER_BALANCE = 1000 * 10**18; // an arbitrarily choosen value

    event MarketCreated(address creator, uint64 marketId);

    event OracleCreated(address oracleOwner, uint64 oracleId);

    event OracleOwnerChanged(address oracleOwner, uint64 oracleId);

    event CustomerRegistered(
        address customer,
        uint64 marketId,
        bytes data
    );

    event DonateCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to,
        bytes data
    );

    event StakeCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to,
        bytes data
    );

    event TakeBackCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to
    );

    event ConvertStakedToDonated(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        address sender,
        uint256 amount,
        address to,
        bytes data
    );

    event ReportedNumerator(
        uint64 indexed oracleId,
        address customer,
        uint256 numerator
    );

    event ReportedNumeratorsBatch(
        uint64 indexed oracleId,
        address[] addresses,
        uint256[] numerators
    );

    event OracleFinished(address indexed oracleOwner);

    event RedeemCalculated(
        address user,
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 indexed marketId,
        uint64 indexed oracleId,
        address condition,
        uint payout
    );

    event CollateralWithdrawn(
        IERC1155 contractAdrress,
        uint256 collateralTokenId,
        uint64 marketId,
        uint64 oracleId,
        address user,
        uint256 amount
    );
    
    uint64 private maxId;

    // Mapping from oracleId to oracle owner.
    mapping(uint64 => address) private oracleOwnersMap;
    // Mapping (oracleId => time) the least allowed time of oracles to finish.
    mapping(uint64 => uint) private minFinishTimes;
    // Whether an oracle finished its work.
    mapping(uint64 => bool) private oracleFinishedMap;
    // Mapping (marketId => (customer => numerator)) for payout numerators.
    mapping(uint64 => mapping(address => uint256)) private payoutNumeratorsMap;
    // Mapping (marketId => denominator) for payout denominators.
    mapping(uint64 => uint) private payoutDenominatorMap;
    // All conditional tokens,
    mapping(uint256 => bool) private conditionalTokensMap;
    // Total collaterals (separately donated and staked) per marketId and oracleId: collateral => (marketId => (oracleId => total)).
    mapping(uint256 => uint256) private collateralTotalsMap;
    // The user lost the right to transfer conditional tokens: (user => (conditionalToken => bool)).
    mapping(address => mapping(uint256 => bool)) private userUsedRedeemMap;
    // Mapping (token => (user => amount)) used to calculate withdrawal of collateral amounts.
    mapping(uint256 => mapping(address => uint256)) private lastCollateralBalanceMap; // TODO: Would getter be useful?
    /// Accounts from which anyone can donate after the time come.
    mapping(address => bool) public bequestedAccounts;

    constructor(string memory uri_) ERC1155WithMappedAddressesAndTotals(uri_) {
        _registerInterface(
            BidOnAddresses(0).onERC1155Received.selector ^
            BidOnAddresses(0).onERC1155BatchReceived.selector
        );
    }

    /// Create a new conditional marketId
    function createMarket() external returns (uint64) {
        uint64 marketId = maxId++;
        emit MarketCreated(msg.sender, marketId);
        return marketId;
    }

    /// Create a new oracle
    function createOracle() external returns (uint64) {
        uint64 oracleId = maxId++;
        oracleOwnersMap[oracleId] = msg.sender;
        emit OracleCreated(msg.sender, oracleId);
        emit OracleOwnerChanged(msg.sender, oracleId);
        return oracleId;
    }

    function changeOracleOwner(address newOracleOwner, uint64 oracleId) public _isOracle(oracleId) {
        oracleOwnersMap[oracleId] = newOracleOwner;
        emit OracleOwnerChanged(newOracleOwner, oracleId);
    }

    function updateMinFinishTime(uint64 oracleId, uint time) public _isOracle(oracleId) {
        require(time >= minFinishTimes[oracleId], "Can't break trust of stakers.");
        minFinishTimes[oracleId] = time;
    }

    function approveUnlimitedBequest(bool _approved) public {
        bequestedAccounts[msg.sender] = _approved;
    }

    /// Donate funds in a ERC1155 token.
    /// First need to approve the contract to spend the token.
    /// Not recommended to donate after any oracle has finished, because funds may be (partially) lost.
    function donate(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 marketId,
        uint64 oracleId,
        uint256 amount,
        address to,
        bytes calldata data) external
    {
        _mint(to, _collateralDonatedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId), amount, data);
        uint donatedCollateralTokenId = _collateralDonatedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId);
        collateralTotalsMap[donatedCollateralTokenId] = collateralTotalsMap[donatedCollateralTokenId].add(amount);
        emit DonateCollateral(collateralContractAddress, collateralTokenId, msg.sender, amount, to, data);
        collateralContractAddress.safeTransferFrom(msg.sender, address(this), collateralTokenId, amount, data); // last against reentrancy attack
    }

    /// Stake funds in a ERC1155 token.
    /// First need to approve the contract to spend the token.
    /// The stake is lost if either: the prediction period ends or the staker loses his private key (e.g. dies).
    /// Not recommended to stake after the oracle has finished, because funds may be (partially) lost (you could not unstake).
    /// TODO: Rename to `bequestCollateral`.
    function stakeCollateral(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 marketId,
        uint64 oracleId,
        uint256 amount,
        address from,
        address to,
        bytes calldata data) external _isApproved(from, oracleId)
    {
        _mint(to, _collateralStakedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId), amount, data);
        uint stakedCollateralTokenId = _collateralStakedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId);
        collateralTotalsMap[stakedCollateralTokenId] = collateralTotalsMap[stakedCollateralTokenId].add(amount);
        emit StakeCollateral(collateralContractAddress, collateralTokenId, msg.sender, amount, to, data);
        collateralContractAddress.safeTransferFrom(from, address(this), collateralTokenId, amount, data); // last against reentrancy attack
    }

    /// If the oracle has not yet finished you can take funds back.
    function takeStakeBack(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 marketId,
        uint64 oracleId,
        uint256 amount,
        address to,
        bytes calldata data) external
    {
        require(!isOracleFinished(oracleId), "too late");
        uint stakedCollateralTokenId = _collateralStakedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId);
        collateralTotalsMap[stakedCollateralTokenId] = collateralTotalsMap[stakedCollateralTokenId].sub(amount);
        collateralContractAddress.safeTransferFrom(address(this), to, stakedCollateralTokenId, amount, data);
        emit TakeBackCollateral(collateralContractAddress, collateralTokenId, msg.sender, amount, to);
    }

    /// Donate funds from your stake.
    function convertStakedToDonated(
        IERC1155 collateralContractAddress,
        uint256 collateralTokenId,
        uint64 marketId,
        uint64 oracleId,
        uint256 amount,
        address from,
        address to,
        bytes calldata data) external _isApproved(from, oracleId)
    {
        // Subtract from staked:
        uint stakedCollateralTokenId = _collateralStakedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId);
        _burn(from, stakedCollateralTokenId, amount);
        collateralTotalsMap[stakedCollateralTokenId] = collateralTotalsMap[stakedCollateralTokenId].sub(amount);
        // Add to donated:
        uint donatedCollateralTokenId = _collateralDonatedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId);
        _mint(to, donatedCollateralTokenId, amount, data);
        collateralTotalsMap[donatedCollateralTokenId] = collateralTotalsMap[donatedCollateralTokenId].add(amount);
        emit ConvertStakedToDonated(collateralContractAddress, collateralTokenId, from, amount, to, data);
    }

    /// Anyone can register himself.
    /// Can be called both before or after the oracle finish. However registering after the finish is useless.
    function registerCustomer(uint64 marketId, bytes calldata data) external {
        uint256 conditionalTokenId = _conditionalTokenId(marketId, originalAddress(msg.sender));
        require(!conditionalTokensMap[conditionalTokenId], "customer already registered");
        conditionalTokensMap[conditionalTokenId] = true;
        _mintToCustomer(conditionalTokenId, INITIAL_CUSTOMER_BALANCE, data);
        emit CustomerRegistered(msg.sender, marketId, data);
    }

    /// @dev Called by the oracle owner for reporting results of conditions.
    function reportNumerator(uint64 oracleId, address condition, uint256 numerator) external
        _isOracle(oracleId)
    {
        _updateNumerator(oracleId, numerator, condition);
        emit ReportedNumerator(oracleId, condition, numerator);
    }

    /// @dev Called by the oracle owner for reporting results of conditions.
    function reportNumeratorsBatch(uint64 oracleId, address[] calldata addresses, uint256[] calldata numerators) external
        _isOracle(oracleId)
    {
        require(addresses.length == numerators.length, "Length mismatch.");
        for (uint i = 0; i < addresses.length; ++i) {
            _updateNumerator(oracleId, numerators[i], addresses[i]);
        }
        emit ReportedNumeratorsBatch(oracleId, addresses, numerators);
    }

    /// Need to be called after all numerators were reported.
    function finishOracle(uint64 oracleId) external
        _isOracle(oracleId)
    {
        oracleFinishedMap[oracleId] = true;
        emit OracleFinished(msg.sender);
    }

    function _calcRewardShare(uint64 oracleId, address condition) private view returns (int128){
        uint256 numerator = payoutNumeratorsMap[oracleId][condition];
        uint256 denominator = payoutDenominatorMap[oracleId];
        return ABDKMath64x64.divu(numerator, denominator);
    }

    function collateralOwingBase(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 marketId, uint64 oracleId, address condition, address user)
        private view returns (uint donatedCollateralTokenId, uint stakedCollateralTokenId, uint256 donated, uint256 staked)
    {
        uint256 conditonalToken = _conditionalTokenId(marketId, condition);
        uint256 conditonalBalance = balanceOf(user, conditonalToken);
        uint256 totalConditonalBalance = totalBalanceOf(conditonalToken);
        donatedCollateralTokenId = _collateralDonatedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId);
        uint256 donatedCollateralTotalBalance = totalBalanceOf(donatedCollateralTokenId);
        stakedCollateralTokenId = _collateralStakedTokenId(collateralContractAddress, collateralTokenId, marketId, oracleId);
        uint256 stakedCollateralTotalBalance = totalBalanceOf(stakedCollateralTokenId);
        // Rounded to below for no out-of-funds:
        int128 marketIdShare = ABDKMath64x64.divu(conditonalBalance, totalConditonalBalance);
        int128 rewardShare = _calcRewardShare(oracleId, condition);
        uint256 _newDividendsDonated = donatedCollateralTotalBalance - lastCollateralBalanceMap[donatedCollateralTokenId][user];
        uint256 _newDividendsStaked = stakedCollateralTotalBalance - lastCollateralBalanceMap[stakedCollateralTokenId][user];
        int128 multiplier = marketIdShare.mul(rewardShare);
        donated = multiplier.mulu(_newDividendsDonated);
        staked = multiplier.mulu(_newDividendsStaked);
    }
 
    function collateralOwing(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 marketId, uint64 oracleId, address condition, address user) external view returns(uint256) {
        (,, uint256 donated, uint256 staked) = collateralOwingBase(collateralContractAddress, collateralTokenId, marketId, oracleId, condition, user);
        return donated + staked;
    }

    /// Transfer to `msg.sender` the collateral ERC-20 token (we can't transfer to somebody other, because anybody can transfer).
    /// accordingly to the score of `condition` in the marketId by the oracle.
    /// After this function is called, it becomes impossible to transfer the corresponding conditional token of `msg.sender`
    /// (to prevent its repeated withdraw).
    function withdrawCollateral(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 marketId, uint64 oracleId, address condition, bytes calldata data) external {
        require(isOracleFinished(oracleId), "too early"); // to prevent the denominator or the numerators change meantime
        uint256 conditionalTokenId = _conditionalTokenId(marketId, condition);
        userUsedRedeemMap[msg.sender][conditionalTokenId] = true;
        // _burn(msg.sender, conditionalTokenId, conditionalBalance); // Burning it would break using the same token for multiple markets.
        (uint donatedCollateralTokenId, uint stakedCollateralTokenId, uint256 _owingDonated, uint256 _owingStaked) =
            collateralOwingBase(collateralContractAddress, collateralTokenId, marketId, oracleId, condition, msg.sender);

        // Against rounding errors. Not necessary because of rounding down.
        // if(_owing > balanceOf(address(this), collateralTokenId)) _owing = balanceOf(address(this), collateralTokenId);

        if(_owingDonated != 0) {
            lastCollateralBalanceMap[donatedCollateralTokenId][msg.sender] = totalBalanceOf(donatedCollateralTokenId);
        }
        if(_owingStaked != 0) {
            lastCollateralBalanceMap[stakedCollateralTokenId][msg.sender] = totalBalanceOf(stakedCollateralTokenId);
        }
        // Last to prevent reentrancy attack:
        collateralContractAddress.safeTransferFrom(address(this), msg.sender, collateralTokenId, _owingDonated + _owingStaked, data);
    }

    /// Disallow transfers of conditional tokens after redeem to prevent "gathering" them before redeeming each oracle.
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes calldata data
    )
        public override
    {
        _checkTransferAllowed(id, from);
        _baseSafeTransferFrom(from, to, id, value, data);
    }

    /// Disallow transfers of conditional tokens after redeem to prevent "gathering" them before redeeming each oracle.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    )
        public override
    {
        for(uint i = 0; i < ids.length; ++i) {
            _checkTransferAllowed(ids[i], from);
        }
        _baseSafeBatchTransferFrom(from, to, ids, values, data);
    }

    /// Don't send funds to us directy (they will be lost!), use smart contract API.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) public pure override returns(bytes4) {
        return this.onERC1155Received.selector; // to accept transfers
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) public pure override returns(bytes4) {
        return bytes4(0); // We should never receive batch transfers.
    }

    // Getters //

    function summaryCollateral(address user, uint256 donatedCollateralTokenId, uint256 stakedCollateralTokenId) public view returns (uint256) {
        return balanceOf(user, donatedCollateralTokenId) + balanceOf(user, stakedCollateralTokenId);
    }

    function summaryCollateralTotal(uint256 donatedCollateralTokenId, uint256 stakedCollateralTokenId) public view returns (uint256) {
        return collateralTotalsMap[donatedCollateralTokenId] + collateralTotalsMap[stakedCollateralTokenId];
    }

    function oracleOwner(uint64 oracleId) public view returns (address) {
        return oracleOwnersMap[oracleId];
    }

    function isOracleFinished(uint64 oracleId) public view returns (bool) {
        return oracleFinishedMap[oracleId] && block.timestamp >= minFinishTimes[oracleId];
    }

    function payoutNumerator(uint64 marketId, address condition) public view returns (uint256) {
        return payoutNumeratorsMap[marketId][condition];
    }

    function payoutDenominator(uint64 marketId) public view returns (uint256) {
        return payoutDenominatorMap[marketId];
    }

    function isConditionalToken(uint256 tokenId) public view returns (bool) {
        return conditionalTokensMap[tokenId];
    }

    /// @param hash should be a result of `_collateralStakedTokenId()`.
    function collateralTotal(uint256 hash) public view returns (uint256) {
        return collateralTotalsMap[hash];
    }

    function isConditonalLocked(address holder, uint256 conditionalTokenId) public view returns (bool) {
        return userUsedRedeemMap[holder][conditionalTokenId];
    }

    function minFinishTime(uint64 oracleId) public view returns (uint) {
        return minFinishTimes[oracleId];
    }

    // Internal //

    function _conditionalTokenId(uint64 marketId, address condition) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint8(TokenKind.TOKEN_CONDITIONAL), marketId, condition)));
    }

    function _collateralDonatedTokenId(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 marketId, uint64 oracleId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint8(TokenKind.TOKEN_DONATED), collateralContractAddress, collateralTokenId, marketId, oracleId)));
    }

    function _collateralStakedTokenId(IERC1155 collateralContractAddress, uint256 collateralTokenId, uint64 marketId, uint64 oracleId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(uint8(TokenKind.TOKEN_STAKED), collateralContractAddress, collateralTokenId, marketId, oracleId)));
    }

    function _checkTransferAllowed(uint256 id, address from) internal view {
        require(!userUsedRedeemMap[originalAddress(from)][id], "You can't trade conditional tokens after redeem.");
    }

    function _baseSafeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    )
        private
    {
        require(to != address(0), "ERC1155: target address must be non-zero");
        require(
            from == msg.sender || _operatorApprovals[from][msg.sender] == true,
            "ERC1155: need operator approval for 3rd party transfers."
        );

        _doTransfer(id, from, to, value);

        emit TransferSingle(msg.sender, from, to, id, value);

        _doSafeTransferAcceptanceCheck(msg.sender, from, to, id, value, data);
    }

    function _baseSafeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    )
        private
    {
        require(ids.length == values.length, "ERC1155: IDs and values must have same lengths");
        require(to != address(0), "ERC1155: target address must be non-zero");
        require(
            from == msg.sender || _operatorApprovals[from][msg.sender] == true,
            "ERC1155: need operator approval for 3rd party transfers."
        );

        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 value = values[i];

            _doTransfer(id, from, to, value);
        }

        emit TransferBatch(msg.sender, from, to, ids, values);

        _doSafeBatchTransferAcceptanceCheck(msg.sender, from, to, ids, values, data);
    }

    function _doTransfer(uint256 id, address from, address to, uint256 value) internal {
        address originalFrom = originalAddress(from);
        _balances[id][originalFrom] = _balances[id][originalFrom].sub(value);
        address originalTo = originalAddress(to);
        _balances[id][originalTo] = value.add(_balances[id][originalTo]);
    }

    function _updateNumerator(uint64 oracleId, uint256 numerator, address condition) private {
        payoutDenominatorMap[oracleId] = payoutDenominatorMap[oracleId].add(numerator).sub(payoutNumeratorsMap[oracleId][condition]);
        payoutNumeratorsMap[oracleId][condition] = numerator;
    }

    // Virtual functions //

    function _mintToCustomer(uint256 conditionalTokenId, uint256 amount, bytes calldata data) internal virtual {
        _mint(msg.sender, conditionalTokenId, amount, data);
    }

    modifier _isOracle(uint64 oracleId) {
        require(oracleOwnersMap[oracleId] == msg.sender, "Not the oracle owner.");
        _;
    }

    modifier _isApproved(address from, uint64 oracleId) {
        require(from == msg.sender || (bequestedAccounts[from] && isOracleFinished(oracleId)),
                "Putting funds not approved.");
        _;
    }
}
