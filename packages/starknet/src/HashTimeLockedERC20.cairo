use starknet::ContractAddress;

#[starknet::interface]
pub trait IMessenger<TContractState> {
    fn notifyHTLC(
        ref self: TContractState,
        htlcId: u256,
        sender: ContractAddress,
        srcAddress: ContractAddress,
        amount: u256,
        timelock: u256,
        hashlock: u256,
        dstAddress: felt252,
        phtlcId: u256,
        tokenContract: ContractAddress,
    );
}

#[starknet::interface]
pub trait IHashedTimelockERC20<TContractState> {
    fn createP(
        ref self: TContractState,
        chainIds: Span<u256>,
        assetIds: Span<u256>,
        LpPath: Span<felt252>,
        dstChainId: u256,
        dstAssetId: u256,
        dstAddress: felt252,
        srcAssetId: u256,
        srcAddress: ContractAddress,
        timelock: u256,
        messenger: ContractAddress,
        tokenContract: ContractAddress,
        amount: u256,
    ) -> u256;
    fn create(
        ref self: TContractState,
        _srcAddress: ContractAddress,
        _hashlock: u256,
        _timelock: u256,
        _tokenContract: ContractAddress,
        _amount: u256,
        _chainId: u256,
        _dstAddress: felt252,
        _phtlcId: u256,
        _messenger: ContractAddress,
    ) -> u256;
    fn redeem(ref self: TContractState, htlcId: u256, _secret: felt252) -> bool;
    fn refundP(ref self: TContractState, phtlcId: u256) -> bool;
    fn refund(ref self: TContractState, htlcId: u256) -> bool;
    fn convertP(ref self: TContractState, phtlcId: u256, hashlock: u256) -> u256;
    fn getPHTLCDetails(
        self: @TContractState, phtlcId: u256
    ) -> (
        (ContractAddress, ContractAddress, ContractAddress, ContractAddress),
        (u256, u256, u256),
        (bool, bool),
        felt252
    );
    fn getHTLCDetails(
        self: @TContractState, htlcId: u256
    ) -> (
        (ContractAddress, ContractAddress, ContractAddress),
        (u256, u256, u256),
        (bool, bool),
        felt252
    );
}

/// @title Pre Hashed Timelock Contracts (PHTLCs) on Starknet ERC20 tokens.
///
/// This contract provides a way to create and keep PHTLCs for ERC20 tokens.
///
/// Protocol:
///
///  1) create(srcAddress, hashlock, timelock, tokenContract, amount) - a
///      sender calls this to create a new HTLC on a given token (tokenContract)
///       for a given amount. A uint256 htlcId is returned
///  2) redeem(htlcId, secret) - once the srcAddress knows the secret of
///      the hashlock hash they can claim the tokens with this function
///  3) refund(htlcId) - after timelock has expired and if the srcAddress did not
///      redeem the tokens the sender / creator of the HTLC can get their tokens
///      back with this function.
#[starknet::contract]
mod HashedTimelockERC20 {
    use core::clone::Clone;
    use core::array::ArrayTrait;
    use core::num::traits::Zero;
    use starknet::ContractAddress;
    use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
    use core::traits::Into;
    use starknet::get_caller_address;
    use starknet::get_contract_address;
    use starknet::get_block_timestamp;
    //TODO: Check if this should be IERC20SafeDispatcher 
    use openzeppelin::token::erc20::interface::IERC20Dispatcher;
    use alexandria_math::sha256::sha256;
    use alexandria_bytes::Bytes;
    use alexandria_bytes::BytesTrait;
    use super::IMessenger;
    use super::IMessengerDispatcherTrait;
    use super::IMessengerDispatcher;

    #[storage]
    struct Storage {
        counter: u256,
        htlc: HTLC,
        contracts: LegacyMap::<u256, HTLC>,
        pContracts: LegacyMap::<u256, PHTLC>,
    }
    //TDOO: check if this should be public?
    #[derive(Drop, Serde, starknet::Store)]
    struct HTLC {
        hashlock: u256,
        secret: felt252,
        amount: u256,
        timelock: u256,
        sender: ContractAddress,
        srcAddress: ContractAddress,
        tokenContract: ContractAddress,
        redeemed: bool,
        refunded: bool,
    }
    #[derive(Drop, Serde, starknet::Store)]
    struct PHTLC {
        dstAddress: felt252, //TODO: check what type is this 
        srcAssetId: u256,
        sender: ContractAddress,
        srcAddress: ContractAddress,
        amount: u256,
        timelock: u256,
        messenger: ContractAddress,
        tokenContract: ContractAddress,
        refunded: bool,
        converted: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TokenTransferPreInitiated: TokenTransferPreInitiated,
        TokenTransferInitiated: TokenTransferInitiated,
        TokenTransferClaimed: TokenTransferClaimed,
        TokenTransferRefunded: TokenTransferRefunded,
        TokenTransferRefundedP: TokenTransferRefundedP,
    }
    #[derive(Drop, starknet::Event)]
    struct TokenTransferPreInitiated {
        chainIds: Span<u256>,
        assetIds: Span<u256>,
        LpPath: Span<felt252>,
        phtlcId: u256,
        dstChainId: u256,
        dstAssetId: u256,
        dstAddress: felt252,
        #[key]
        sender: ContractAddress,
        srcAssetId: u256,
        #[key]
        srcAddress: ContractAddress,
        timelock: u256,
        messenger: ContractAddress,
        amount: u256,
        tokenContract: ContractAddress,
    }
    #[derive(Drop, starknet::Event)]
    struct TokenTransferInitiated {
        #[key]
        hashlock: u256,
        amount: u256,
        chainId: u256,
        timelock: u256,
        #[key]
        sender: ContractAddress,
        #[key]
        srcAddress: ContractAddress,
        tokenContract: ContractAddress,
        dstAddress: felt252,
        phtlcId: u256,
    }
    #[derive(Drop, starknet::Event)]
    struct TokenTransferClaimed {
        #[key]
        htlcId: u256,
        redeemAddress: ContractAddress,
    }
    #[derive(Drop, starknet::Event)]
    struct TokenTransferRefunded {
        #[key]
        htlcId: u256
    }
    #[derive(Drop, starknet::Event)]
    struct TokenTransferRefundedP {
        #[key]
        phtlcId: u256
    }
    #[constructor]
    fn constructor(ref self: ContractState) {
        self.counter.write(0);
    }
    #[abi(embed_v0)]
    impl HashedTimelockERC20 of super::IHashedTimelockERC20<ContractState> {
        /// @dev Sender / Payer sets up a new pre-hash time lock contract depositing the
        /// funds and providing the reciever/srcAddress and terms.
        /// @param _srcAddress reciever/srcAddress of the funds.
        /// @param _timelock UNIX epoch seconds time that the lock expires at.
        ///                  Refunds can be made after this time.
        /// @return Id of the new PHTLC. This is needed for subsequent calls.
        fn createP(
            ref self: ContractState,
            chainIds: Span<u256>,
            assetIds: Span<u256>,
            LpPath: Span<felt252>,
            dstChainId: u256,
            dstAssetId: u256,
            dstAddress: felt252,
            srcAssetId: u256,
            srcAddress: ContractAddress,
            timelock: u256,
            messenger: ContractAddress,
            tokenContract: ContractAddress,
            amount: u256,
        ) -> u256 {
            assert!(timelock > get_block_timestamp().into(), "Not Future TimeLock");
            assert!(amount != 0, "Funds Can Not Be Zero");

            let phtlcId = self.counter.read() + 1;
            self.counter.write(phtlcId);

            let token: IERC20Dispatcher = IERC20Dispatcher { contract_address: tokenContract };
            assert!(token.balance_of(get_caller_address()) >= amount, "Insufficient Balance");
            assert!(
                token.allowance(get_caller_address(), get_contract_address()) >= amount,
                "No Enough Allowence"
            );

            token.transfer_from(get_caller_address(), get_contract_address(), amount);

            self
                .pContracts
                .write(
                    phtlcId,
                    PHTLC {
                        dstAddress: dstAddress,
                        srcAssetId: srcAssetId,
                        sender: get_caller_address(),
                        srcAddress: srcAddress,
                        amount: amount,
                        timelock: timelock,
                        messenger: messenger,
                        tokenContract: tokenContract,
                        refunded: false,
                        converted: false,
                    }
                );
            self
                .emit(
                    TokenTransferPreInitiated {
                        chainIds: chainIds,
                        assetIds: assetIds,
                        LpPath: LpPath,
                        phtlcId: phtlcId,
                        dstChainId: dstChainId,
                        dstAssetId: dstAssetId,
                        dstAddress: dstAddress,
                        sender: get_caller_address(),
                        srcAssetId: srcAssetId,
                        srcAddress: srcAddress,
                        timelock: timelock,
                        messenger: messenger,
                        amount: amount,
                        tokenContract: tokenContract,
                    }
                );
            phtlcId
        }

        /// @dev Sender / Payer sets up a new hash time lock contract depositing the
        /// funds and providing the reciever and terms.
        /// @param _srcAddress srcAddress of the funds.
        /// @param _hashlock A sha-256 hash hashlock.
        /// @param _timelock UNIX epoch seconds time that the lock expires at.
        ///                  Refunds can be made after this time.
        /// @return Id of the new HTLC. This is needed for subsequent calls.
        fn create(
            ref self: ContractState,
            _srcAddress: ContractAddress,
            _hashlock: u256,
            _timelock: u256,
            _tokenContract: ContractAddress,
            _amount: u256,
            _chainId: u256,
            _dstAddress: felt252,
            _phtlcId: u256,
            _messenger: ContractAddress,
        ) -> u256 {
            assert!(_timelock > get_block_timestamp().into(), "Not Future TimeLock");
            assert!(_amount != 0, "Funds Can Not Be Zero");

            let htlcId = _hashlock;
            assert!(!self.hasHTLC(htlcId), "HTLC Already Exists");

            let token: IERC20Dispatcher = IERC20Dispatcher { contract_address: _tokenContract };
            assert!(token.balance_of(get_caller_address()) >= _amount, "Insufficient Balance");
            assert!(
                token.allowance(get_caller_address(), get_contract_address()) >= _amount,
                "No Enough Allowence"
            );

            token.transfer_from(get_caller_address(), get_contract_address(), _amount);
            self
                .contracts
                .write(
                    htlcId,
                    HTLC {
                        hashlock: _hashlock,
                        secret: 0,
                        amount: _amount,
                        timelock: _timelock,
                        sender: get_caller_address(),
                        srcAddress: _srcAddress,
                        tokenContract: _tokenContract,
                        redeemed: false,
                        refunded: false
                    }
                );
            self
                .emit(
                    TokenTransferInitiated {
                        hashlock: _hashlock,
                        amount: _amount,
                        chainId: _chainId,
                        timelock: _timelock,
                        sender: get_caller_address(),
                        srcAddress: _srcAddress,
                        tokenContract: _tokenContract,
                        dstAddress: _dstAddress,
                        phtlcId: _phtlcId,
                    }
                );
            if !_messenger.is_zero() {
                let messenger: IMessengerDispatcher = IMessengerDispatcher {
                    contract_address: _messenger
                };
                messenger
                    .notifyHTLC(
                        htlcId,
                        get_caller_address(),
                        _srcAddress,
                        _amount,
                        _timelock,
                        _hashlock,
                        _dstAddress,
                        _phtlcId,
                        _tokenContract,
                    );
            }
            htlcId
        }

        /// @dev Called by the srcAddress once they know the secret of the hashlock.
        /// This will transfer the locked funds to their address.
        ///
        /// @param htlcId of the HTLC.
        /// @param _secret sha256(_secret) should equal the contract hashlock.
        /// @return bool true on success
        fn redeem(ref self: ContractState, htlcId: u256, _secret: felt252) -> bool {
            assert!(self.hasHTLC(htlcId), "HTLC Does Not Exist");
            let htlc: HTLC = self.contracts.read(htlcId);

            let mut bytes: Bytes = BytesTrait::new(0, array![]);
            bytes.append_felt252(_secret);
            let pre = bytes.sha256();
            let mut bytes: Bytes = BytesTrait::new(0, array![]);
            bytes.append_u256(pre);
            let hash_pre = bytes.sha256();
            assert!(htlc.hashlock == hash_pre, "Does Not Match the Hashlock");
            assert!(!htlc.redeemed, "Funds Are Alredy Redeemed");
            assert!(!htlc.refunded, "Funds Are Alredy Refunded");
            self
                .contracts
                .write(
                    htlcId,
                    HTLC {
                        hashlock: htlc.hashlock,
                        secret: _secret,
                        amount: htlc.amount,
                        timelock: htlc.timelock,
                        sender: htlc.sender,
                        srcAddress: htlc.srcAddress,
                        tokenContract: htlc.tokenContract,
                        redeemed: true,
                        refunded: htlc.refunded
                    }
                );
            IERC20Dispatcher { contract_address: htlc.tokenContract }
                .transfer(htlc.srcAddress, htlc.amount);
            self.emit(TokenTransferClaimed { htlcId: htlcId, redeemAddress: get_caller_address() });
            true
        }

        /// @dev Called by the sender if there was no redeem OR convert AND the time lock has
        /// expired. This will refund the contract amount.
        ///
        /// @param _phtlcId of the PHTLC to refund from.
        /// @return bool true on success
        fn refundP(ref self: ContractState, phtlcId: u256) -> bool {
            assert!(self.hasPHTLC(phtlcId), "PHTLC Does Not Exist");
            let phtlc: PHTLC = self.pContracts.read(phtlcId);

            assert!(!phtlc.refunded, "Funds Are Already Refunded");
            assert!(!phtlc.converted, "Already Converted to HTLC");
            assert!(phtlc.timelock <= get_block_timestamp().into(), "Not Passed Time Lock");

            self
                .pContracts
                .write(
                    phtlcId,
                    PHTLC {
                        dstAddress: phtlc.dstAddress,
                        srcAssetId: phtlc.srcAssetId,
                        sender: phtlc.sender,
                        srcAddress: phtlc.srcAddress,
                        amount: phtlc.amount,
                        timelock: phtlc.timelock,
                        messenger: phtlc.messenger,
                        tokenContract: phtlc.tokenContract,
                        refunded: true,
                        converted: phtlc.converted,
                    }
                );
            IERC20Dispatcher { contract_address: phtlc.tokenContract }
                .transfer(phtlc.sender, phtlc.amount);
            self.emit(TokenTransferRefunded { htlcId: phtlcId });
            true
        }
        /// @dev Called by the sender to convert the PHTLC to HTLC
        /// expired. This will refund the contract amount.
        ///
        /// @param _phtlcId of the PHTLC to convert.
        /// @param hashlock of the HTLC to be converted.
        /// @return id of the converted HTLC
        fn convertP(ref self: ContractState, phtlcId: u256, hashlock: u256) -> u256 {
            assert!(self.hasPHTLC(phtlcId), "PHTLC Does Not Exist");
            let htlcId = hashlock;
            let phtlc: PHTLC = self.pContracts.read(phtlcId);

            assert!(!phtlc.refunded, "Can't convert refunded PHTLC");
            assert!(!phtlc.converted, "Already Converted to HTLC");
            assert!(
                get_caller_address() == phtlc.sender || get_caller_address() == phtlc.messenger,
                "No Allowance"
            );
            self
                .pContracts
                .write(
                    phtlcId,
                    PHTLC {
                        dstAddress: phtlc.dstAddress,
                        srcAssetId: phtlc.srcAssetId,
                        sender: phtlc.sender,
                        srcAddress: phtlc.srcAddress,
                        amount: phtlc.amount,
                        timelock: phtlc.timelock,
                        messenger: phtlc.messenger,
                        tokenContract: phtlc.tokenContract,
                        refunded: phtlc.refunded,
                        converted: true,
                    }
                );
            self
                .contracts
                .write(
                    htlcId,
                    HTLC {
                        hashlock: hashlock,
                        secret: 0,
                        amount: phtlc.amount,
                        timelock: phtlc.timelock,
                        sender: phtlc.sender,
                        srcAddress: phtlc.srcAddress,
                        tokenContract: phtlc.tokenContract,
                        redeemed: false,
                        refunded: false
                    }
                );
            htlcId
        }

        /// @dev Get HTLC details.
        /// @param htlcId of the HTLC.
        fn getHTLCDetails(
            self: @ContractState, htlcId: u256
        ) -> (
            (ContractAddress, ContractAddress, ContractAddress),
            (u256, u256, u256),
            (bool, bool),
            felt252
        ) {
            if !self.hasHTLC(htlcId) {
                return (
                    (Zero::zero(), Zero::zero(), Zero::zero()),
                    (0_u256, 0_u256, 0_u256),
                    (false, false),
                    0
                );
            }
            let htlc: HTLC = self.contracts.read(htlcId);
            (
                (htlc.sender, htlc.srcAddress, htlc.tokenContract),
                (htlc.amount, htlc.hashlock, htlc.timelock),
                (htlc.redeemed, htlc.refunded),
                htlc.secret
            )
        }
        fn getPHTLCDetails(
            self: @ContractState, phtlcId: u256
        ) -> (
            (ContractAddress, ContractAddress, ContractAddress, ContractAddress),
            (u256, u256, u256),
            (bool, bool),
            felt252
        ) {
            if !self.hasPHTLC(phtlcId) {
                return (
                    (Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero()),
                    (0_u256, 0_u256, 0_u256),
                    (false, false),
                    0
                );
            }
            let phtlc: PHTLC = self.pContracts.read(phtlcId);
            (
                (phtlc.sender, phtlc.srcAddress, phtlc.tokenContract, phtlc.messenger),
                (phtlc.amount, phtlc.srcAssetId, phtlc.timelock),
                (phtlc.refunded, phtlc.converted),
                phtlc.dstAddress
            )
        }
    }

    #[generate_trait]
    //TODO: Check if this functions be inline?
    impl InternalFunctions of InternalFunctionsTrait {
        /// @dev Check if there is a PHTLC with a given id.
        /// @param phtlcId into PHTLC mapping.
        fn hasPHTLC(self: @ContractState, phtlcId: u256) -> bool {
            let exists: bool = (!self.pContracts.read(phtlcId).sender.is_zero());
            exists
        }

        /// @dev Check if there is a HTLC with a given id.
        /// @param htlcId into HTLC mapping.
        fn hasHTLC(self: @ContractState, htlcId: u256) -> bool {
            let exists: bool = (!self.contracts.read(htlcId).sender.is_zero());
            exists
        }
    }
}
