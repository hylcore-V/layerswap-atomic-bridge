// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title Hashed Timelock Contracts (HTLCs) for Ethereum.
 *
 * This contract provides a way to create and keep HTLCs for Ether (ETH).
 *
 * Protocol:
 *
 *  1) create(receiver, hashlock, timelock) - a sender calls this to create
 *      a new HTLC and gets back a 32 byte contract id
 *  2) redeem(htlcId, secret) - once the receiver knows the secret of
 *      the hashlock hash they can claim the Ether with this function
 *  3) refund() - after the timelock has expired and if the receiver did not
 *      redeem funds, the sender/creator of the HTLC can get their Ether
 *      back with this function.
 */
contract HashedTimeLockEther {
  error FundsNotSent();
  error NotFutureTimelock();
  error NotPassedTimelock();
  error ContractAlreadyExist();
  error HTLCNotExists();
  error HashlockNotMatch();
  error AlreadyRedeemed();
  error AlreadyRefunded();
  error IncorrectData();

  struct HTLC {
    bytes32 hashlock;
    bytes32 secret;
    uint256 amount;
    uint256 timelock;
    address payable sender;
    address payable receiver;
    bool redeemed;
    bool refunded;
  }

  mapping(bytes32 => HTLC) contracts;

  event EtherTransferInitiated(
    bytes32 indexed hashlock,
    uint256 amount,
    uint256 chainID,
    uint256 timelock,
    address indexed sender,
    address indexed receiver,
    string targetCurrencyReceiverAddress
  );
  event EtherTransferClaimed(bytes32 indexed htlcId);
  event EtherTransferRefunded(bytes32 indexed htlcId);

  modifier htlcExists(bytes32 _htlcId) {
    if (!hasHTLC(_htlcId)) revert HTLCNotExists();
    _;
  }

  /**
   * @dev Sender sets up a new hash time lock contract depositing the Ether and
   * providing the receiver lock terms.
   *
   * @param _receiver Receiver of the Ether.
   * @param _hashlock A sha-256 hash hashlock.
   * @param _timelock UNIX epoch seconds time that the lock expires at.
   *                  Refunds can be made after this time.
   * @return htlcId Id of the new HTLC. This is needed for subsequent
   *                    calls
   **/
  function create(
    address payable _receiver,
    bytes32 _hashlock,
    uint256 _timelock,
    uint256 _chainID,
    string memory _targetCurrencyReceiverAddress
  ) external payable returns (bytes32 htlcId) {
    if (msg.value == 0) {
      revert FundsNotSent();
    }
    if (_timelock <= block.timestamp) {
      revert NotFutureTimelock();
    }

    if (hasHTLC(_hashlock)) {
      revert ContractAlreadyExist();
    }
    htlcId = _hashlock;
    contracts[_hashlock] = HTLC(_hashlock, 0x0, msg.value, _timelock, payable(msg.sender), _receiver, false, false);

    emit EtherTransferInitiated(
      _hashlock,
      msg.value,
      _chainID,
      _timelock,
      msg.sender,
      _receiver,
      _targetCurrencyReceiverAddress
    );
  }

  function createBatch(
    address payable[] memory _receivers,
    bytes32[] memory _hashlocks,
    uint256[] memory _timelocks,
    uint256[] memory _chainIDs,
    string[] memory _targetCurrencyReceiversAddresses,
    uint[] memory _amounts
  ) external payable returns (bytes32[] memory htlcIds) {
    
    htlcIds = new bytes32[](_receivers.length);
    if (msg.value == 0) {
      revert FundsNotSent();
    }

    uint result = 0;

    for (uint i = 0; i < _amounts.length; i++) {
      if (_amounts[i] == 0) {
        revert FundsNotSent();
      }
      result += _amounts[i];
    }

    if (
      _receivers.length == 0 ||
      _receivers.length != _hashlocks.length ||
      _receivers.length != _timelocks.length ||
      _receivers.length != _chainIDs.length ||
      _receivers.length != _targetCurrencyReceiversAddresses.length ||
      result != msg.value
    ) {
      revert IncorrectData();
    }

    for (uint i = 0; i < _receivers.length; i++) {
      if (_timelocks[i] <= block.timestamp) {
        revert NotFutureTimelock();
      }
      htlcIds[i] = _hashlocks[i];

      if (hasHTLC(htlcIds[i])) {
        revert ContractAlreadyExist();
      }

      contracts[htlcIds[i]] = HTLC(
        _hashlocks[i],
        0x0,
        _amounts[i],
        _timelocks[i],
        payable(msg.sender),
        _receivers[i],
        false,
        false
      );

      emit EtherTransferInitiated(
        _hashlocks[i],
        _amounts[i],
        _chainIDs[i],
        _timelocks[i],
        msg.sender,
        _receivers[i],
        _targetCurrencyReceiversAddresses[i]
      );
    }
  }

  /**
   * @dev Called by the receiver once they know the secret of the hashlock.
   * This will transfer the locked funds to their address.
   *
   * @param _htlcId Id of the HTLC.
   * @param _secret sha256(_secret) should equal the contract hashlock.
   * @return bool true on success
   */
  function redeem(bytes32 _htlcId, bytes32 _secret) external htlcExists(_htlcId) returns (bool) {
    HTLC storage htlc = contracts[_htlcId];

    bytes32 pre = sha256(abi.encodePacked(_secret));
    if (htlc.hashlock != sha256(abi.encodePacked(pre))) revert HashlockNotMatch();
    if (htlc.refunded) revert AlreadyRefunded();
    if (htlc.redeemed) revert AlreadyRedeemed();
    if (htlc.timelock <= block.timestamp) revert NotFutureTimelock();

    htlc.secret = _secret;
    htlc.redeemed = true;
    htlc.receiver.transfer(htlc.amount);
    emit EtherTransferClaimed(_htlcId);
    return true;
  }

  /**
   * @notice Allows multiple HTLCs to be redeemed in a batch.
   * @dev This function is used to redeem funds from multiple HTLCs simultaneously, providing the corresponding secrets for each HTLC.
   * @param _htlcIds An array of HTLC contract IDs to be redeemed.
   * @param _secrets An array of secrets corresponding to the HTLCs.
   * @return A boolean indicating whether the batch redemption was successful.
   * @dev Emits an `BatchEtherTransfersCompleted` event upon successful redemption of all specified HTLCs.
   */
  function batchRedeem(bytes32[] memory _htlcIds, bytes32[] memory _secrets) external returns (bool) {
    if (_htlcIds.length != _secrets.length) {
      revert IncorrectData();
    }
    for (uint256 i; i < _htlcIds.length; i++) {
      if (!hasHTLC(_htlcIds[i])) revert HTLCNotExists();
    }
    uint256 totalToRedeem;
    address payable _receiver = contracts[_htlcIds[0]].receiver;
    for (uint256 i; i < _htlcIds.length; i++) {
      HTLC storage htlc = contracts[_htlcIds[i]];
      bytes32 pre = sha256(abi.encodePacked(_secrets[i]));
      if (htlc.hashlock != sha256(abi.encodePacked(pre))) revert HashlockNotMatch();
      if (htlc.refunded) revert AlreadyRefunded();
      if (htlc.redeemed) revert AlreadyRedeemed();
      if (htlc.timelock <= block.timestamp) revert NotFutureTimelock();

      htlc.secret = _secrets[i];
      htlc.redeemed = true;
      if (_receiver == htlc.receiver) {
        totalToRedeem += htlc.amount;
      } else {
        htlc.receiver.transfer(htlc.amount);
      }
      emit EtherTransferClaimed(_htlcIds[i]);
    }
    _receiver.transfer(totalToRedeem);
    return true;
  }

  /**
   * @dev Called by the sender if there was no redeem AND the time lock has
   * expired. This will refund the contract amount.
   *
   * @param _htlcId Id of HTLC to refund from.
   * @return bool true on success
   */
  function refund(bytes32 _htlcId) external htlcExists(_htlcId) returns (bool) {
    HTLC storage htlc = contracts[_htlcId];

    if (htlc.refunded) revert AlreadyRefunded();
    if (htlc.redeemed) revert AlreadyRedeemed();
    if (htlc.timelock > block.timestamp) revert NotPassedTimelock();

    htlc.refunded = true;
    htlc.sender.transfer(htlc.amount);
    emit EtherTransferRefunded(_htlcId);
    return true;
  }

  /**
   * @dev Get contract details.
   * @param _htlcId HTLC contract id
   **/
  function getHTLCDetails(
    bytes32 _htlcId
  )
    public
    view
    returns (
      address sender,
      address receiver,
      uint256 amount,
      bytes32 hashlock,
      uint256 timelock,
      bool redeemed,
      bool refunded,
      bytes32 secret
    )
  {
    if (!hasHTLC(_htlcId)) {
      return (address(0), address(0), 0, 0, 0, false, false, 0);
    }
    HTLC storage htlc = contracts[_htlcId];
    return (
      htlc.sender,
      htlc.receiver,
      htlc.amount,
      htlc.hashlock,
      htlc.timelock,
      htlc.redeemed,
      htlc.refunded,
      htlc.secret
    );
  }

  /**
   * @dev Check if there is a contract with a given id.
   * @param _htlcId Id into contracts mapping.
   **/
  function hasHTLC(bytes32 _htlcId) internal view returns (bool exists) {
    exists = (contracts[_htlcId].sender != address(0));
  }
}
