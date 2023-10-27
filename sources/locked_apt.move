/**
 * This provides an example for staked locked APT where a sponsor can create locks of staked APTs for recipients.
 * This code uses the Amnis protocol for APT liquid staking. More information at https://amnis.finance/.
 * Recipients can claim staking rewards (as stAPT) at any time but can only claim the original locked amount as stAPT
 * after the specified lock expiration.
 *
 * Locked coins flow:
 * 1. Deploy the lockup contract. Deployer can decide if the contract is upgradable or not.
 * Follow the instructions in README.md for deploying.
 * 2. Sponsor accounts (sponsors) call initialize_sponsor to set up their account for creating locks later.
 * 2. Sponsors add locked APTs with create_lock for custom expiration time + amount for recipients.
 * Each lockup is called a "lock". This automatically stake APT with the Amnis Protocol and return the staked stAPT to
 * stay in the lock.
 * 3. Sponsors can revoke a lock or change lockup (reduce or extend) anytime. This gives flexibility in case of
 * contract violation or special circumstances. If this is not desired, the deployer can remove these functionalities
 * before deploying. If a lock is canceled, the locked stAPT will be sent back to the withdrawal address. This
 * withdrawal address is set when initilizing the sponsor account and can only be changed when there are no active or
 * unclaimed locks.
 * 4. Sponsors can decide to relock the stAPT with create_locked_with_stapt.
 * 5. Recipients can withdraw staking rewards when there are some at any time by calling claim_rewards.
 * 6. Once the lockup has expired, the recipient can call claim to get the unlocked stAPT. They can then either keep
 * them or redeem with the Amnis protocol (https://stake.amnis.finance/stake?q=unstake).
 **/
module locked_apt::locked_apt {
    use amnis::router;
    use amnis::stapt_token::{Self, StakedApt};
    use aptos_framework::aptos_account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_std::math64;
    use aptos_std::smart_table::{Self, SmartTable};
    use std::signer;
    use std::vector;

    /// No locked coins found to claim.
    const ELOCK_NOT_FOUND: u64 = 1;
    /// Lockup has not expired yet.
    const ELOCKUP_HAS_NOT_EXPIRED: u64 = 2;
    /// Can only create one active lock per recipient at once.
    const ELOCK_ALREADY_EXISTS: u64 = 3;
    /// Sponsor account has not been set up to create locks for the specified CoinType yet.
    const ESPONSOR_ACCOUNT_NOT_INITIALIZED: u64 = 4;
    /// Cannot update the withdrawal address because there are still active/unclaimed locks.
    const EACTIVE_LOCKS_EXIST: u64 = 5;

    /// Represents a lock of staked APT until some specified unlock time. Afterward, the recipient can claim the coins.
    struct Lock has store {
        coins: Coin<StakedApt>,
        // Track the principal to allow recipients to claim the rewards at any time.
        principal: u64,
        unlock_time_secs: u64,
    }

    /// Holder for a map from recipients => locks.
    /// There can be at most one lock per recipient.
    struct Locks has key {
        // Map from recipient address => locked coins.
        locks: SmartTable<address, Lock>,
        // Predefined withdrawal address. This cannot be changed if there's any active lock.
        withdrawal_address: address,
        // Number of locks that have not yet been claimed.
        total_locks: u64,
    }

    #[event]
    /// Event emitted when a lock is created.
    struct CreateLockEvent has drop, store {
        recipient: address,
        amount: u64,
        amount_stapt: u64,
    }

    #[event]
    /// Event emitted when a lock is canceled.
    struct CancelLockupEvent has drop, store {
        recipient: address,
        amount: u64,
        amount_stapt: u64,
    }

    #[event]
    /// Event emitted when a recipient claims rewards.
    struct ClaimRewardsEvent has drop, store {
        recipient: address,
        amount: u64,
        amount_stapt: u64,
    }

    #[event]
    /// Event emitted when a recipient claims unlocked stAPT.
    struct ClaimEvent has drop, store {
        recipient: address,
        amount: u64,
        amount_stapt: u64,
        claimed_time_secs: u64,
    }

    #[event]
    /// Event emitted when lockup is updated for an existing lock.
    struct UpdateLockupEvent has drop, store {
        recipient: address,
        old_unlock_time_secs: u64,
        new_unlock_time_secs: u64,
    }

    #[event]
    /// Event emitted when withdrawal address is updated.
    struct UpdateWithdrawalAddressEvent has drop, store {
        old_withdrawal_address: address,
        new_withdrawal_address: address,
    }

    #[view]
    /// Return the total number of locks created by the sponsor for the given CoinType.
    public fun total_locks(sponsor: address): u64 acquires Locks {
        assert!(exists<Locks>(sponsor), ESPONSOR_ACCOUNT_NOT_INITIALIZED);
        let locks = borrow_global<Locks>(sponsor);
        locks.total_locks
    }

    #[view]
    /// Return the number of coins a sponsor has locked up for the given recipient.
    /// This throws an error if there are no locked APT setup for the given recipient.
    public fun locked_amount_stapt(sponsor: address, recipient: address): u64 acquires Locks {
        assert!(exists<Locks>(sponsor), ESPONSOR_ACCOUNT_NOT_INITIALIZED);
        let locks = borrow_global<Locks>(sponsor);
        assert!(smart_table::contains(&locks.locks, recipient), ELOCK_NOT_FOUND);
        coin::value(&smart_table::borrow(&locks.locks, recipient).coins)
    }

    #[view]
    public fun locked_amount_apt(sponsor: address, recipient: address): u64 acquires Locks {
        let stapt_amount = locked_amount_stapt(sponsor, recipient);
        math64::mul_div(
            stapt_amount,
            stapt_token::stapt_price(),
            stapt_token::precision_u64(),
        )
    }

    #[view]
    /// Return the timestamp (in seconds) when the given recipient can claim coins locked up for them by the sponsor.
    /// This throws an error if there are no locked coins setup for the given recipient.
    public fun claim_time_secs(sponsor: address, recipient: address): u64 acquires Locks {
        assert!(exists<Locks>(sponsor), ESPONSOR_ACCOUNT_NOT_INITIALIZED);
        let locks = borrow_global<Locks>(sponsor);
        assert!(smart_table::contains(&locks.locks, recipient), ELOCK_NOT_FOUND);
        smart_table::borrow(&locks.locks, recipient).unlock_time_secs
    }

    #[view]
    /// Return the withdrawal address for a sponsor's locks (where canceled locks' funds are sent to).
    public fun withdrawal_address(sponsor: address): address acquires Locks {
        assert!(exists<Locks>(sponsor), ESPONSOR_ACCOUNT_NOT_INITIALIZED);
        let locks = borrow_global<Locks>(sponsor);
        locks.withdrawal_address
    }

    /// Initialize the sponsor account to allow creating locks.
    public entry fun initialize_sponsor(sponsor: &signer, withdrawal_address: address) {
        move_to(sponsor, Locks {
            locks: smart_table::new(),
            withdrawal_address,
            total_locks: 0,
        })
    }

    /// Update the withdrawal address. This is only allowed if there are currently no active locks.
    public entry fun update_withdrawal_address(
        sponsor: &signer, new_withdrawal_address: address) acquires Locks {
        let sponsor_address = signer::address_of(sponsor);
        assert!(exists<Locks>(sponsor_address), ESPONSOR_ACCOUNT_NOT_INITIALIZED);

        let locks = borrow_global_mut<Locks>(sponsor_address);
        assert!(locks.total_locks == 0, EACTIVE_LOCKS_EXIST);
        let old_withdrawal_address = locks.withdrawal_address;
        locks.withdrawal_address = new_withdrawal_address;

        event::emit(UpdateWithdrawalAddressEvent {
            old_withdrawal_address,
            new_withdrawal_address,
        });
    }

    /// Batch version of add_locked_coins to process multiple recipients and corresponding amounts.
    public entry fun batch_create_lock(
        sponsor: &signer, recipients: vector<address>, amounts: vector<u64>, unlock_time_secs: u64) acquires Locks {
        vector::zip(recipients, amounts, |recipient, amount| {
            create_lock(sponsor, recipient, amount, unlock_time_secs);
        });
    }

    /// `Sponsor` can add locked APT for `recipient` with given unlock timestamp (in seconds).
    /// There's no restriction on unlock timestamp so sponsors could technically add APT for an unlocked time in the
    /// past, which means the coins are immediately unlocked.
    /// APT added is automatically staked and the returned stAPT is locked.
    public entry fun create_lock(
        sponsor: &signer, recipient: address, amount: u64, unlock_time_secs: u64) acquires Locks {
        let apt = coin::withdraw<AptosCoin>(sponsor, amount);
        let stapt = router::deposit_and_stake(apt);
        create_lock_internal(get_locks(signer::address_of(sponsor)), stapt, recipient, unlock_time_secs);
    }

    public entry fun batch_create_lock_with_stapt(
        sponsor: &signer, recipients: vector<address>, amounts: vector<u64>, unlock_time_secs: u64) acquires Locks {
        vector::zip(recipients, amounts, |recipient, amount| {
            create_lock_with_stapt(sponsor, recipient, amount, unlock_time_secs);
        });
    }

    public entry fun create_lock_with_stapt(
        sponsor: &signer, recipient: address, amount: u64, unlock_time_secs: u64) acquires Locks {
        let stapt = coin::withdraw<StakedApt>(sponsor, amount);
        create_lock_internal(get_locks(signer::address_of(sponsor)), stapt, recipient, unlock_time_secs);
    }

    /// Recipient can claim staking rewards generated as stAPT.
    public entry fun claim_rewards(recipient: &signer, sponsor: address) acquires Locks {
        let recipient_address = signer::address_of(recipient);

        let lock = get_lock(sponsor, recipient_address);
        let current_value = math64::mul_div(
            coin::value(&lock.coins),
            stapt_token::stapt_price(),
            stapt_token::precision_u64(),
        );
        let accumulated_rewards = current_value - lock.principal;
        let amount_to_redeem = math64::mul_div(
            accumulated_rewards,
            stapt_token::precision_u64(),
            stapt_token::stapt_price(),
        );
        let stapt_to_redeem = coin::extract(&mut lock.coins, amount_to_redeem);
        aptos_account::deposit_coins(recipient_address, stapt_to_redeem);

        event::emit(ClaimRewardsEvent {
            recipient: recipient_address,
            amount: accumulated_rewards,
            amount_stapt: amount_to_redeem,
        });
    }

    /// Recipient can claim stAPT that are fully unlocked (unlock time has passed).
    public entry fun claim(recipient: &signer, sponsor: address) acquires Locks {
        let locks = get_locks(sponsor);
        let recipient_address = signer::address_of(recipient);
        assert!(smart_table::contains(&locks.locks, recipient_address), ELOCK_NOT_FOUND);

        // Delete the lock entry both to keep records clean and keep storage usage minimal.
        // This would be reverted if validations fail later (transaction atomicity).
        let Lock {
            coins,
            principal: _,
            unlock_time_secs,
        } = smart_table::remove(&mut locks.locks, recipient_address);
        locks.total_locks = locks.total_locks - 1;
        let now_secs = timestamp::now_seconds();
        assert!(now_secs >= unlock_time_secs, ELOCKUP_HAS_NOT_EXPIRED);

        let amount_stapt = coin::value(&coins);
        let amount = math64::mul_div(
            amount_stapt,
            stapt_token::stapt_price(),
            stapt_token::precision_u64(),
        );
        aptos_account::deposit_coins(recipient_address, coins);

        event::emit(ClaimEvent {
            recipient: recipient_address,
            amount_stapt,
            amount,
            claimed_time_secs: now_secs,
        });
    }

    /// Batch version of update_lockup.
    public entry fun batch_update_lockup(
        sponsor: &signer, recipients: vector<address>, new_unlock_time_secs: u64) acquires Locks {
        vector::for_each_ref(&recipients, |recipient| {
            update_lockup(sponsor, *recipient, new_unlock_time_secs);
        });
    }

    /// Sponsor can update the lockup of an existing lock.
    public entry fun update_lockup(
        sponsor: &signer, recipient: address, new_unlock_time_secs: u64) acquires Locks {
        let lock = get_lock(signer::address_of(sponsor), recipient);
        let old_unlock_time_secs = lock.unlock_time_secs;
        lock.unlock_time_secs = new_unlock_time_secs;

        event::emit(UpdateLockupEvent {
            recipient,
            old_unlock_time_secs,
            new_unlock_time_secs,
        });
    }

    /// Batch version of cancel_lockup to cancel the lockup for multiple recipients.
    public entry fun batch_cancel_lockup(sponsor: &signer, recipients: vector<address>) acquires Locks {
        vector::for_each_ref(&recipients, |recipient| {
            cancel_lockup(sponsor, *recipient);
        });
    }

    /// Sponsor can cancel an existing lock.
    public entry fun cancel_lockup(sponsor: &signer, recipient: address) acquires Locks {
        let locks = get_locks(signer::address_of(sponsor));
        assert!(smart_table::contains(&locks.locks, recipient), ELOCK_NOT_FOUND);

        // Remove the lock and deposit coins backed into the sponsor account.
        let Lock {
            coins,
            principal: _,
            unlock_time_secs: _,
        } = smart_table::remove(&mut locks.locks, recipient);
        locks.total_locks = locks.total_locks - 1;
        let amount_stapt = coin::value(&coins);
        let amount = math64::mul_div(
            amount_stapt,
            stapt_token::stapt_price(),
            stapt_token::precision_u64(),
        );
        aptos_account::deposit_coins(locks.withdrawal_address, coins);

        event::emit(CancelLockupEvent {
            recipient,
            amount_stapt,
            amount,
        });
    }

    inline fun get_lock(sponsor: address, recipient: address): &mut Lock {
        let locks = get_locks(sponsor);
        assert!(smart_table::contains(&locks.locks, recipient), ELOCK_NOT_FOUND);
        smart_table::borrow_mut(&mut locks.locks, recipient)
    }

    inline fun get_locks(sponsor: address): &mut Locks {
        assert!(exists<Locks>(sponsor), ESPONSOR_ACCOUNT_NOT_INITIALIZED);
        borrow_global_mut<Locks>(sponsor)
    }

    fun create_lock_internal(
        locks: &mut Locks, staked_apt: Coin<StakedApt>, recipient: address, unlock_time_secs: u64) {
        assert!(!smart_table::contains(&locks.locks, recipient), ELOCK_ALREADY_EXISTS);
        let principal =
            math64::mul_div(coin::value(&staked_apt), stapt_token::stapt_price(), stapt_token::precision_u64());
        smart_table::add(&mut locks.locks, recipient, Lock {
            coins: staked_apt,
            principal,
            unlock_time_secs,
        });
        locks.total_locks = locks.total_locks + 1;
    }
}
