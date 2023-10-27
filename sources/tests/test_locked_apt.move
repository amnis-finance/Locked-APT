#[test_only]
module locked_apt::test_locked_apt {
    use amnis::stapt_token::{Self, StakedApt};
    use amnis::test_helpers;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_std::math64;
    use locked_apt::locked_apt;
    use std::features;
    use std::signer;

    #[test_only]
    fun setup(sponsor: &signer) {
        test_helpers::set_up();
        test_helpers::initialize_test_validator_custom(@0xcafe1, 10, 0);
        features::change_feature_flags(
            &account::create_signer_for_test(@0x1),
            vector[features::get_module_event_feature()],
            vector[],
        );

        account::create_account_for_test(signer::address_of(sponsor));
        coin::register<AptosCoin>(sponsor);
        test_helpers::mint_apt_to(sponsor, 1000);
    }

    #[test(sponsor = @0x123, recipient = @0x234)]
    public entry fun test_recipient_can_claim_coins(sponsor: &signer, recipient: &signer) {
        setup(sponsor);
        let recipient_addr = signer::address_of(recipient);
        let sponsor_address = signer::address_of(sponsor);
        locked_apt::initialize_sponsor(sponsor, sponsor_address);
        let principal = 1000 * test_helpers::one_apt();
        locked_apt::create_lock(sponsor, recipient_addr, principal, timestamp::now_seconds() + 100000);
        assert!(locked_apt::total_locks(sponsor_address) == 1, 0);
        assert!(locked_apt::locked_amount_apt(sponsor_address, recipient_addr) == principal, 0);

        // Claim rewards
        test_helpers::end_epoch_and_update_rewards();
        let locked_amount_with_rewards = locked_apt::locked_amount_apt(sponsor_address, recipient_addr);
        let expected_rewards = math64::mul_div(
            locked_amount_with_rewards - principal,
            stapt_token::precision_u64(),
            stapt_token::stapt_price(),
        );
        locked_apt::claim_rewards(recipient, sponsor_address);
        assert!(coin::balance<StakedApt>(recipient_addr) == expected_rewards, 0);

        // Claim after lockup expires.
        timestamp::fast_forward_seconds(100000);
        locked_apt::claim(recipient, sponsor_address);
        assert!(locked_apt::total_locks(sponsor_address) == 0, 1);
        let expected_claimed = math64::mul_div(
            1000 * test_helpers::one_apt(),
            stapt_token::precision_u64(),
            stapt_token::stapt_price(),
        );
        assert!(coin::balance<StakedApt>(recipient_addr) == expected_rewards + expected_claimed, 0);
    }

    #[test(sponsor = @0x123, recipient = @0x234)]
    #[expected_failure(abort_code = locked_apt::locked_apt::ELOCKUP_HAS_NOT_EXPIRED, location = locked_apt)]
    public entry fun test_recipient_cannot_claim_coins_if_lockup_has_not_expired(sponsor: &signer, recipient: &signer) {
        setup(sponsor);
        let recipient_addr = signer::address_of(recipient);
        let sponsor_address = signer::address_of(sponsor);
        locked_apt::initialize_sponsor(sponsor, sponsor_address);
        locked_apt::create_lock(sponsor, recipient_addr, 1000 * test_helpers::one_apt(), timestamp::now_seconds() + 1000);
        timestamp::fast_forward_seconds(500);
        locked_apt::claim(recipient, sponsor_address);
    }

    #[test(sponsor = @0x123, recipient = @0x234)]
    #[expected_failure(abort_code = locked_apt::locked_apt::ELOCK_NOT_FOUND, location = locked_apt)]
    public entry fun test_recipient_cannot_claim_twice(sponsor: &signer, recipient: &signer) {
        setup(sponsor);
        let recipient_addr = signer::address_of(recipient);
        let sponsor_address = signer::address_of(sponsor);
        locked_apt::initialize_sponsor(sponsor, sponsor_address);
        locked_apt::create_lock(sponsor, recipient_addr, 1000 * test_helpers::one_apt(), timestamp::now_seconds() + 1000);
        timestamp::fast_forward_seconds(1000);
        locked_apt::claim(recipient, sponsor_address);
        locked_apt::claim(recipient, sponsor_address);
    }

    #[test(sponsor = @0x123, recipient = @0x234)]
    public entry fun test_sponsor_can_update_lockup(sponsor: &signer, recipient: &signer) {
        setup(sponsor);
        let recipient_addr = signer::address_of(recipient);
        let sponsor_address = signer::address_of(sponsor);
        locked_apt::initialize_sponsor(sponsor, sponsor_address);
        locked_apt::create_lock(sponsor, recipient_addr, 1000 * test_helpers::one_apt(), timestamp::now_seconds() + 1000);
        assert!(locked_apt::total_locks(sponsor_address) == 1, 0);
        assert!(locked_apt::claim_time_secs(sponsor_address, recipient_addr) == timestamp::now_seconds() + 1000, 0);
        // Extend lockup.
        locked_apt::update_lockup(sponsor, recipient_addr, timestamp::now_seconds() + 2000);
        assert!(locked_apt::claim_time_secs(sponsor_address, recipient_addr) == timestamp::now_seconds() + 2000, 1);
        // Reduce lockup.
        locked_apt::update_lockup(sponsor, recipient_addr, timestamp::now_seconds() + 1500);
        assert!(locked_apt::claim_time_secs(sponsor_address, recipient_addr) == timestamp::now_seconds() + 1500, 2);
        assert!(locked_apt::total_locks(sponsor_address) == 1, 1);
    }

    #[test(sponsor = @0x123, recipient = @0x234, withdrawal = @0x345)]
    public entry fun test_sponsor_can_cancel_lockup(sponsor: &signer, recipient: &signer, withdrawal: &signer) {
        setup(sponsor);
        let recipient_addr = signer::address_of(recipient);
        let withdrawal_addr = signer::address_of(withdrawal);
        let sponsor_address = signer::address_of(sponsor);
        locked_apt::initialize_sponsor(sponsor, withdrawal_addr);
        locked_apt::create_lock(sponsor, recipient_addr, 1000 * test_helpers::one_apt(), timestamp::now_seconds() + 1000);
        assert!(locked_apt::total_locks(sponsor_address) == 1, 0);
        let locked_amount = locked_apt::locked_amount_stapt(sponsor_address, recipient_addr);
        locked_apt::cancel_lockup(sponsor, recipient_addr);
        assert!(locked_apt::total_locks(sponsor_address) == 0, 0);

        // Funds from canceled locks should be sent to the withdrawal address.
        assert!(coin::balance<StakedApt>(withdrawal_addr) == locked_amount, 0);
    }

    #[test(sponsor = @0x123, recipient = @0x234, withdrawal = @0x456)]
    #[expected_failure(abort_code = locked_apt::locked_apt::EACTIVE_LOCKS_EXIST, location = locked_apt)]
    public entry fun test_cannot_change_withdrawal_address_if_active_locks_exist(
        sponsor: &signer,
        recipient: &signer,
        withdrawal: &signer,
    ) {
        setup(sponsor);
        let recipient_addr = signer::address_of(recipient);
        let withdrawal_addr = signer::address_of(withdrawal);
        let sponsor_address = signer::address_of(sponsor);
        locked_apt::initialize_sponsor(sponsor, withdrawal_addr);
        locked_apt::create_lock(sponsor, recipient_addr, 1000 * test_helpers::one_apt(), 1000);
        locked_apt::update_withdrawal_address(sponsor, sponsor_address);
    }

    #[test(sponsor = @0x123, recipient = @0x234, withdrawal = @0x456)]
    public entry fun test_can_change_withdrawal_address_if_no_active_locks_exist(
        sponsor: &signer,
        recipient: &signer,
        withdrawal: &signer,
    ) {
        setup(sponsor);
        let recipient_addr = signer::address_of(recipient);
        let withdrawal_addr = signer::address_of(withdrawal);
        let sponsor_address = signer::address_of(sponsor);
        locked_apt::initialize_sponsor(sponsor, withdrawal_addr);
        assert!(locked_apt::withdrawal_address(sponsor_address) == withdrawal_addr, 0);
        locked_apt::create_lock(sponsor, recipient_addr, 1000 * test_helpers::one_apt(), 1000);
        locked_apt::cancel_lockup(sponsor, recipient_addr);
        locked_apt::update_withdrawal_address(sponsor, sponsor_address);
        assert!(locked_apt::withdrawal_address(sponsor_address) == sponsor_address, 0);
    }
}
