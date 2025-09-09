module usdy_vault::vault_scripts {
    use std::signer;
    use std::bcs;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::option::{Option};
    use aptos_framework::object::{Self, Object, ExtendRef};

    use aptos_std::math64;

    use thala_protocol_interface::vault;
    use thala_protocol_interface::mod_coin::{MOD};

    use fixed_point64::fixed_point64::{Self};

    use lending::lending::{Self, Market};

    use usdy_vault::eusdy_wrapper::{Self, EUSDY};
    use usdy_vault::package;

    use usdy_alias::usdy_coin::{USDY};

    const BPS_BASE: u64 = 10000;
    const DEFAULT_CR: u64 = 10500; // 105% CR

    struct SmartSigner has key {
        smart_signer_extend_ref: ExtendRef
    }

    // Errors
    const ERR_INSUFFICIENT_SHARES: u64 = 0;
    const ERR_USDY_VAULT_UNINITIALIZED: u64 = 1;
    const ERR_INSUFFICIENT_INPUT: u64 = 2;

    public entry fun deposit_usdy_entry(user: &signer, usdy_coin_amount: u64, mod_market_obj: Object<Market>, thala_vault_hint: Option<address>) {
        deposit_usdy(user, coin::withdraw<USDY>(user, usdy_coin_amount), mod_market_obj, thala_vault_hint)
    }

    public fun deposit_usdy(user: &signer, usdy_coin: Coin<USDY>, mod_market_obj: Object<Market>, thala_vault_hint: Option<address>) {
        assert!(coin::value(&usdy_coin) > 0, ERR_INSUFFICIENT_INPUT);
        let eusdy_coin = eusdy_wrapper::mint_eusdy(usdy_coin);

        // Generate / fetch smart signer of user
        let smart_signer = &generate_smart_signer(signer::address_of(user));

        // When borrowing, fees are ADDED on top of the amount of MOD we wish to withdraw
        // collateral / liability = 105% CR => eUSDY amount / (MOD amount + fees) = 105% CR
        // (MOD amount + fees) * 105% CR = eUSDY amount => MOD amount = (eUSDY amount * 100 / 105) - fees
        let usdy_amount = coin::value(&eusdy_coin);
        let fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(vault::borrow_fee_ratio(), usdy_amount));
        let amount_to_borrow = math64::mul_div(usdy_amount, BPS_BASE, DEFAULT_CR) - fee_amount;

        // If this is a first time deposit, open a vault, else add onto existing vault
        let mod_coin;
        if (!vault::opened_vault<EUSDY>(signer::address_of(smart_signer))) {
            mod_coin = vault::open_vault<EUSDY>(smart_signer, eusdy_coin, amount_to_borrow, thala_vault_hint);
        } else {
            vault::deposit_collateral<EUSDY>(smart_signer, eusdy_coin, thala_vault_hint);
            mod_coin = vault::borrow<EUSDY>(smart_signer, amount_to_borrow, thala_vault_hint);
        };

        lending::supply<MOD>(smart_signer, mod_market_obj, mod_coin);
    }

    public entry fun withdraw_usdy_entry(user: &signer, amount_usdy: u64, extra_mod_coin_amount: u64, mod_market_obj: Object<Market>, thala_vault_hint: Option<address>) { 
        let (usdy, mod) = withdraw_usdy(user, amount_usdy, coin::withdraw<MOD>(user, extra_mod_coin_amount), mod_market_obj, thala_vault_hint);
        coin::deposit<USDY>(signer::address_of(user), usdy);
        coin::deposit<MOD>(signer::address_of(user), mod);
    }

    // extra_mod_coin is used to cover any outstanding liability in the CDP, letting users withdraw
    // all USDY from their position even if CDP ir % > lending apy %
    public fun withdraw_usdy(user: &signer, amount_usdy: u64, extra_mod_coin: Coin<MOD>, mod_market_obj: Object<Market>, thala_vault_hint: Option<address>): (Coin<USDY>, Coin<MOD>) {
        assert!(smart_signer_exists(signer::address_of(user)), ERR_USDY_VAULT_UNINITIALIZED);
        assert!(amount_usdy > 0, ERR_INSUFFICIENT_INPUT);

        // Generate / fetch smart signer of user
        let smart_signer = &generate_smart_signer(signer::address_of(user));
        let smart_signer_addr = signer::address_of(smart_signer);

        // Step backwards to calculate amounts necessary to withdraw from CDP & Lending
        let (collateral, liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);

        // CDP calculation of new liability while maintaining 105% CR 
        let new_collateral = collateral - amount_usdy;
        let new_liability = math64::mul_div(new_collateral, BPS_BASE, DEFAULT_CR);
        let cdp_debt_to_pay = liability - new_liability;

        // If we are exiting the position, withdraw all the MOD possible, else withdraw MOD necessary
        let mod_coins_out = if (new_collateral == 0) {
            lending::account_withdrawable_coins(smart_signer_addr, mod_market_obj)
        } else {
            // Lending calculation of shares to withdraw (we use up to the max withdrawable coins, 
            // at which point we'll use extra_mod_coin to successfully pay off the liability)
            math64::min(cdp_debt_to_pay, lending::account_withdrawable_coins(smart_signer_addr, mod_market_obj))
        };
        
        // check we can withdraw this many shares
        let shares_to_withdraw = lending::coins_to_shares(mod_market_obj, mod_coins_out);
        assert!(shares_to_withdraw <= lending::account_shares(smart_signer_addr, mod_market_obj), ERR_INSUFFICIENT_SHARES);

        // withdraw MOD from echelon & add extra_mod_coin (useful for if CDP IR % > lending APY %
        // as without extra_mod_coin we can never fully exit CDP and retrieve all the USDY in vault)
        let mod_coin = lending::withdraw<MOD>(smart_signer, mod_market_obj, shares_to_withdraw);
        coin::merge(&mut mod_coin, extra_mod_coin);

        // We do this because `vault::repay` could throw an error if too much MOD is supplied
        let mod_amount = coin::value(&mod_coin);
        let extra_mod_out;
        if (cdp_debt_to_pay < mod_amount) {
            extra_mod_out = coin::extract(&mut mod_coin, mod_amount - cdp_debt_to_pay);
        } else {
            extra_mod_out = coin::zero<MOD>();
        };
 
        // withdraw as much as possible eUSDY from CDP
        vault::repay<EUSDY>(smart_signer, mod_coin, thala_vault_hint);
        let eusdy_coin = vault::withdraw_collateral<EUSDY>(smart_signer, amount_usdy, thala_vault_hint);
        
        // burn eUSDY for USDY
        let usdy_coin = eusdy_wrapper::burn_eusdy(eusdy_coin);

        (usdy_coin, extra_mod_out)
    }

    fun generate_smart_signer(user_address: address): signer acquires SmartSigner {
        let seed = bcs::to_bytes(&user_address);
        let smart_signer_addr = object::create_object_address(&package::package_address(), seed);
        
        if (!exists<SmartSigner>(smart_signer_addr)) {
            let smart_signer_cref = object::create_named_object(&package::package_signer(), seed);
            let smart_signer = object::generate_signer(&smart_signer_cref);
            let smart_signer_extend_ref = object::generate_extend_ref(&smart_signer_cref);
            
            move_to<SmartSigner>(&smart_signer, SmartSigner { smart_signer_extend_ref });
        };

        let smart_signer = borrow_global_mut<SmartSigner>(smart_signer_addr);

        object::generate_signer_for_extending(&smart_signer.smart_signer_extend_ref)
    }

    #[view]
    public fun smart_signer_exists(user_address: address): bool {
        let seed = bcs::to_bytes(&user_address);
        let smart_signer_addr = object::create_object_address(&package::package_address(), seed);
        exists<SmartSigner>(smart_signer_addr)
    }

    #[view]
    public fun smart_signer_address(user_address: address): address {
        let seed = bcs::to_bytes(&user_address);
        object::create_object_address(&package::package_address(), seed)
    }

    #[view]
    public fun withdrawable_usdy(user_address: address, mod_market_obj: Object<Market>): u64 {
        let smart_signer_addr = smart_signer_address(user_address);

        let withdrawable_mod = lending::account_withdrawable_coins(smart_signer_addr, mod_market_obj);
        let (collateral, liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);

        if (withdrawable_mod >= liability) {
            return collateral
        };

        // CDP calculation of new collateral while maintaining 105% CR 
        let new_liability = liability - withdrawable_mod;
        let new_collateral = math64::mul_div(DEFAULT_CR, new_liability, BPS_BASE);
        let amount_usdy = collateral - new_collateral;

        amount_usdy
    }

    #[test_only]
    public fun generate_smart_signer_for_test(user_address: address): signer acquires SmartSigner {
        let seed = bcs::to_bytes(&user_address);
        let smart_signer_addr = object::create_object_address(&package::package_address(), seed);
        
        if (!exists<SmartSigner>(smart_signer_addr)) {
            let smart_signer_cref = object::create_named_object(&package::package_signer(), seed);
            let smart_signer = object::generate_signer(&smart_signer_cref);
            let smart_signer_extend_ref = object::generate_extend_ref(&smart_signer_cref);
            
            move_to<SmartSigner>(&smart_signer, SmartSigner { smart_signer_extend_ref });
        };

        let smart_signer = borrow_global_mut<SmartSigner>(smart_signer_addr);

        object::generate_signer_for_extending(&smart_signer.smart_signer_extend_ref)
    }
}