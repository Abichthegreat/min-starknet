use starknet::ContractAddress;

#[starknet::interface]
trait IERC20<TStorage> {
    #[view]
    fn get_name(self: @TStorage) -> felt252;

    #[view]
    fn get_symbol(self: @TStorage) -> felt252;

    #[view]
    fn get_total_supply(self: @TStorage) -> felt252;

    #[view]
    fn balance_of(self: @TStorage, account: ContractAddress) -> u256;

    #[view]
    fn allowance(self: @TStorage, owner: ContractAddress, spender: ContractAddress) -> u256;

    #[external]
    fn transfer(ref self: TStorage, recipient: ContractAddress, amount: u256);

    #[external]
    fn transfer_from(ref self: TStorage, sender: ContractAddress, recipient: ContractAddress, amount: u256);

    #[external]
    fn approve(ref self: TStorage, spender: ContractAddress, amount: u256);
}

#[starknet::contract]
mod BlindAuction {
    ////////////////////////////////
    // library imports
    ////////////////////////////////
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use starknet::get_contract_address;
    use starknet::contract_address_try_from_felt252;
    use traits::TryInto;
    use traits::Into;
    use option::OptionTrait;
    use integer::u256_from_felt252;
    use starknet::contract_address_to_felt252;

    use starknet::StorageAccess;
    use starknet::StorageBaseAddress;
    use starknet::SyscallResult;
    use starknet::storage_address_from_base_and_offset;
    use starknet::storage_address_from_base;
    use starknet::storage_write_syscall;
    use starknet::storage_read_syscall;

    use super::IERC20DispatcherTrait;
    use super::IERC20Dispatcher;

    ////////////////////////////////
    // HighestBidder struct stores the highest bidder and his bid
    ////////////////////////////////
    #[derive(Copy, Drop)]
    struct HighestBidder {
        bidder: ContractAddress,
        bid: u256,
    }

    ////////////////////////////////
    // storage variables
    ////////////////////////////////
    #[storage]
    struct Storage {
        admin: ContractAddress,
        bidding_ends: u64,
        reveal_ends: u64,
        auction_ended: bool,
        highest_bidder: HighestBidder,
        user_bid: LegacyMap::<ContractAddress, felt252>,
        bid_claim_status: LegacyMap::<ContractAddress, bool>,
    }

    #[event] 
    #[derive(Drop, starknet::Event)]
    enum Event {
        Bidded: Bidded,
        AuctionEnded: AuctionEnded
    }

    ////////////////////////////////
    // Bidded is emitted when a bid is made 
    ////////////////////////////////
    #[derive(Drop, starknet::Event)]
    struct Bidded {
        bidder: ContractAddress,
        bid_commit: felt252
    }

    ////////////////////////////////
    // AuctionEnded is emitted when auction ends
    ////////////////////////////////   
    #[derive(Drop, starknet::Event)]
    struct AuctionEnded {
        winner: ContractAddress,
        highest_bid: u256
    }

    ////////////////////////////////
    // Constructor intialized auction admin, duration for bidding and duration for reveal
    ////////////////////////////////
    #[constructor]
    fn constructor(ref self: Storage, _admin: ContractAddress, _bidding_time: u64, _reveal_time: u64) {
        let current_time: u64 = get_block_timestamp();
        let bidding_end_time = current_time + _bidding_time;
        let reveal_end_time = bidding_end_time + _reveal_time;

        self.admin.write(_admin);
        self.bidding_ends.write(bidding_end_time);
        self.reveal_ends.write(reveal_end_time);
        self.auction_ended.write(false);
    }

    ////////////////////////////////
    // get_winner returns the highest bidder and winner of the auction after auction ends
    ////////////////////////////////
    #[view]
    fn get_winner(self: @Storage) -> ContractAddress {
        let auction_status = self.auction_ended.read();
        assert(auction_status == true, 'auction has not ended');
        let _highest_bidder = self.highest_bidder.read();
        _highest_bidder.bidder
    }

    ////////////////////////////////
    // get_highest_bid returns the winner's bid after auction ends
    ////////////////////////////////
    #[view]
    fn get_highest_bid(self: @Storage) -> u256 {
        let auction_status = self.auction_ended.read();
        assert(auction_status == true, 'auction has not ended');
        let _highest_bidder = self.highest_bidder.read();
        _highest_bidder.bid      
    }

    ////////////////////////////////
    // make_bid is called to place a bid 
    ////////////////////////////////
    #[external]
    fn make_bid(ref self: Storage, _bid: u256) {
        let caller = get_caller_address();
        let this_contract = get_contract_address();
        let current_time: u64 = get_block_timestamp();
        let bidding_end_time = self.bidding_ends.read();
        let eth_contract: ContractAddress = contract_address_try_from_felt252(0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7).unwrap();

        // assert bidding time is not over
        assert(current_time < bidding_end_time, 'bidding is ended');
        // assert bid is not zero
        assert(_bid > u256_from_felt252(0), 'bid must be greater than 0');
        // assert user has not bidded beforehand
        let _user_bid = self.user_bid.read(caller);
        assert(_user_bid == 0, 'already placed a bid');

        // hash bid
        let bid_to_felt: felt252 = _bid.low.into();
        let bid_commit = hash(12345, bid_to_felt);

         // check that the user has beforehand approved the address of the BlindAuction contract to spend the bid amount from his ETH balance
        let allowance = IERC20Dispatcher {contract_address: eth_contract}.allowance(caller, this_contract);
        assert(allowance >= _bid, 'approve the bid amount!');
        // transfer the ETH to this contract
        IERC20Dispatcher {contract_address: eth_contract}.transfer_from(caller, this_contract, _bid);

        // add bid to storage
        self.user_bid.write(caller, bid_commit);

        // emit Bidded
        self.emit(Event::Bidded(
            Bidded{bidder: caller, bid_commit: bid_commit}
        ));
    }

    ////////////////////////////////
    // reveal is called to reveal your bid after bidding is over and calculate the highest bidder
    ////////////////////////////////
    #[external]
    fn reveal(ref self: Storage, _bid: u256) {
        let caller = get_caller_address();
        let bid_commit = self.user_bid.read(caller);
        let current_time: u64 = get_block_timestamp();
        let bidding_end_time = self.bidding_ends.read();
        let reveal_end_time = self.reveal_ends.read();

        // assert bid time is over and reveal time is not
        assert(current_time > bidding_end_time && current_time < reveal_end_time, 'not the right time for reveal');

        // hash bid and check its equal to user's bid_commit
        let bid_to_felt: felt252 = _bid.low.into();
        let bid_hash = hash(12345, bid_to_felt);
        assert(bid_commit == bid_hash, 'invalid bid!');

        // check if bid is higher than the highest bid and thus make it the new highest bid
        let _highest_bidder: HighestBidder = self.highest_bidder.read();
        let _highest_bid = _highest_bidder.bid;
        if(_bid > _highest_bid) {
            let _highest_bidder = HighestBidder { bidder: caller, bid: _bid };
            self.highest_bidder.write(_highest_bidder);
            return ();
        } else {
            return ();
        }
    }

    ////////////////////////////////
    // end_auction is called by the auction admin to end auction after reveal is over and transfer highest bid to admin
    ////////////////////////////////
    #[external]
    fn end_auction(ref self: Storage) {
        let caller = get_caller_address();
        let admin_address = self.admin.read();
        let current_time: u64 = get_block_timestamp();
        let reveal_end_time = self.reveal_ends.read();
        let _highest_bidder = self.highest_bidder.read();
        let eth_contract: ContractAddress = contract_address_try_from_felt252(0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7).unwrap();

        // check that caller is the auction admin
        assert(caller == admin_address, 'caller is not admin!');
        // check that reveal time has ended
        assert(current_time > reveal_end_time, 'reveal has not ended!');

        // transfer highest bid deposit to admin
        let _highest_bid = _highest_bidder.bid;
        IERC20Dispatcher {contract_address: eth_contract}.transfer(admin_address, _highest_bid);

        // change highest_bidder claim status to true, to ensure he can't try to claim back his tokens
        self.bid_claim_status.write(_highest_bidder.bidder, true);

        // end Auction 
        self.auction_ended.write(true);
        // emit AuctionEnded 
        self.emit(Event::AuctionEnded(
            AuctionEnded{winner: _highest_bidder.bidder, highest_bid: _highest_bid}
        ));
    }

    ////////////////////////////////
    // claim_lost_bid is called by other members of the auction to withdraw their bid commitment after winner is announced
    ////////////////////////////////
    #[external]
    fn claim_lost_bid(ref self: Storage, _bid: u256) {
        let caller = get_caller_address();
        let auction_status = self.auction_ended.read();
        let bid_commit = self.user_bid.read(caller);
        let eth_contract: ContractAddress = contract_address_try_from_felt252(0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7).unwrap();
        
        // check auction has ended
        assert(auction_status == true, 'auction has not ended!');

        // check caller has not claimed previously
        let claim_status = self.bid_claim_status.read(caller);
        assert(claim_status == false, 'you do not have claim rights!');

        // hash bid and check its equal to user's bid_commit
        let bid_to_felt: felt252 = _bid.low.into();
        let bid_hash = hash(12345, bid_to_felt);
        assert(bid_commit == bid_hash, 'invalid bid!');

        // refund user
        IERC20Dispatcher {contract_address: eth_contract}.transfer(caller, _bid);

        // mark user as refunded
        self.bid_claim_status.write(caller, true);
    }

    ////////////////////////////////
    // internal function for hashing a value with a salt
    ////////////////////////////////
    fn hash(salt: felt252, value_to_hash: felt252) -> felt252 {
        pedersen(salt, value_to_hash)
    }

    ////////////////////////////////
    // Storage Access implementation for HighestBidder Struct - such a PITA, hopefully we won't need to do this in the future
    ////////////////////////////////
    impl HighestBidderStorageAccess of StorageAccess::<HighestBidder> {
        fn write(address_domain: u32, base: StorageBaseAddress, value: HighestBidder) -> SyscallResult::<()>{
            storage_write_syscall(
                address_domain,
                storage_address_from_base(base),
                contract_address_to_felt252(value.bidder)
            );
            storage_write_syscall(
                address_domain,
                storage_address_from_base(base),
                value.bid.low.into()
            )
        }

        fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<HighestBidder> {
            let bidder_result = storage_read_syscall(
                address_domain,
                storage_address_from_base(base)
            )?;

            let bid_result = storage_read_syscall(
                address_domain,
                storage_address_from_base(base)
            )?;

            Result::Ok(
                HighestBidder {
                    bidder: contract_address_try_from_felt252(bidder_result).unwrap(),
                    bid: u256_from_felt252(bid_result),
                }
            )
        }

        fn write_at_offset_internal(address_domain: u32,  base: StorageBaseAddress, offset: u8, value: HighestBidder) -> SyscallResult::<()> {
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset),
                contract_address_to_felt252(value.bidder)
            );
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset + 1_u8),
                value.bid.low.into()
            )
        }

        fn read_at_offset_internal(address_domain: u32, base: StorageBaseAddress, offset: u8) -> SyscallResult::<HighestBidder> {
            let bidder_result = storage_read_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset)
            )?;

            let bid_result = storage_read_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, offset + 1_u8)
            )?;

            Result::Ok(
                HighestBidder {
                    bidder: contract_address_try_from_felt252(bidder_result).unwrap(),
                    bid: u256_from_felt252(bid_result),
                }
            )
        }

        fn size_internal(value: HighestBidder) -> u8 {
            2_u8
        }
    }
}
