#[test_only]
module usdy_vault::vault_tests {
    use std::option;
    use std::signer;

    use aptos_framework::coin::{Self, MintCapability};
    use aptos_framework::account;
    use aptos_framework::object::{Object};
    use aptos_framework::timestamp;

    use thala_protocol_interface::vault;
    use thala_protocol_interface::mod_coin::{Self, MOD};

    use lending::lending::{Self, Market};
    use lending::lending_tests;
    use lending::coin_test;

    use usdy_vault::eusdy_wrapper::{Self, EUSDY};

    use fixed_point64::fixed_point64::{Self, FixedPoint64};

    use usdy_alias::usdy_coin::{Self, USDY};

    use usdy_vault::package;
    use usdy_vault::vault_scripts;

    const BPS_BASE: u64 = 10000;
    const DEFAULT_CR: u64 = 10500; // 105% CR
    const MOD_MANTISSA: u64 = 100000000;
    const SECONDS_PER_DAY: u64 = 86400;

    // Errors
    const ERR_INSUFFICIENT_SHARES: u64 = 0;

    struct TestUSDC {}

    fun init_for_test(manager: &signer, usdy_vault: &signer): (MintCapability<USDY>, Object<Market>, Object<Market>) {
        let mint_cap = eusdy_wrapper::init_for_test();

        mod_coin::initialize_for_test();

        // initialize a MOD market with initial liquidity of 1000
        lending_tests::init_for_test_external(manager);
        let mod_market_obj = lending_tests::init_market_for_test_external<MOD>(manager, mod_coin::mint(MOD_MANTISSA * 1000));

        // initialize a USDC market for a mock borrower to use
        coin_test::initialize_fake_coin_with_decimals<TestUSDC>(usdy_vault, 8);
        let usdc_market_obj = lending_tests::init_market_for_test_external<TestUSDC>(manager, coin_test::mint_coin<TestUSDC>(usdy_vault, MOD_MANTISSA * 1000));

        (mint_cap, mod_market_obj, usdc_market_obj)
    }

    fun mock_borrower_for_test(usdy_vault: &signer, mock_borrower: &signer, usdc_market_obj: Object<Market>, mod_market_obj: Object<Market>) {
        // Mock a borrower on echelon so we can see interest accrue for user's supply position
        let usdc_coin = coin_test::mint_coin<TestUSDC>(usdy_vault, MOD_MANTISSA * 100);
        lending::supply<TestUSDC>(mock_borrower, usdc_market_obj, usdc_coin);
        let borrowed_mod = lending::borrow<MOD>(mock_borrower, mod_market_obj, MOD_MANTISSA * 10);
        mod_coin::burn(borrowed_mod);
    }

    #[test(manager = @0xBEEF, usdy_vault = @usdy_vault, user = @0xCAFE)]
    public fun deposit_usdy_ok(manager: &signer, usdy_vault: &signer, user: &signer) {
        let (mint_cap, mod_market_obj, usdc_market_obj) = init_for_test(manager, usdy_vault);

        //
        // Deposit into USDY Treasury
        // 
        
        let usdy_amount = 10000000;
        let usdy_coin = coin::mint<USDY>(usdy_amount, &mint_cap);
        vault_scripts::deposit_usdy(user, usdy_coin, mod_market_obj, option::none());

        let smart_signer_addr = vault_scripts::smart_signer_address(signer::address_of(user));

        let (vault_collateral, vault_liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let echelon_mod_amount = lending::shares_to_coins(mod_market_obj, shares);

        assert!(vault_collateral == usdy_amount, 0);

        // MOD taken out + fee
        let vault_fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(vault::borrow_fee_ratio(), echelon_mod_amount));
        assert!(vault_liability == echelon_mod_amount + vault_fee_amount, 0);

        // Ensure we keep 105% CR
        assert!(vault_collateral / vault_liability == DEFAULT_CR / BPS_BASE, 0);

        // check we could withdraw 99% of what we put in (- 1% borrow fee)
        let withdrawable_usdy = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);
        let echelon = 10000;
        assert!((usdy_amount - vault_fee_amount) - withdrawable_usdy < echelon, 0);

        // Clean up
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(manager = @0xBEEF, usdy_vault = @usdy_vault, user = @0xCAFE, mock_borrower = @0xDEAD)]
    public fun deposit_usdy_multiple_ok(manager: &signer, usdy_vault: &signer, user: &signer, mock_borrower: &signer) {
        let (mint_cap, mod_market_obj, usdc_market_obj) = init_for_test(manager, usdy_vault);
        
        //
        // Deposit into USDY Treasury
        // 
        
        let usdy_amount = 10000000;
        let usdy_coin = coin::mint<USDY>(usdy_amount, &mint_cap);
        vault_scripts::deposit_usdy(user, usdy_coin, mod_market_obj, option::none());

        let smart_signer_addr = vault_scripts::smart_signer_address(signer::address_of(user));
        let smart_signer = &vault_scripts::generate_smart_signer_for_test(signer::address_of(user));

        let (vault_collateral, vault_liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let echelon_mod_amount = lending::shares_to_coins(mod_market_obj, shares);

        assert!(vault_collateral == usdy_amount, 0);

        // MOD taken out + fee
        let vault_fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(vault::borrow_fee_ratio(), echelon_mod_amount));
        assert!(vault_liability == echelon_mod_amount + vault_fee_amount, 0);

        // Ensure we keep 105% CR
        assert!(vault_collateral / vault_liability == DEFAULT_CR / BPS_BASE, 0);

        // check we could withdraw 99% of what we put in (- 1% borrow fee)
        let withdrawable_usdy = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);
        let echelon = 10000;
        assert!((usdy_amount - vault_fee_amount) - withdrawable_usdy < echelon, 0);

        //
        // Step forwards in time, accruing interest in CDP & lending
        // 
        
        mock_borrower_for_test(usdy_vault, mock_borrower, usdc_market_obj, mod_market_obj);
        // Fast forward 10 days for interest accrual on echelon
        timestamp::fast_forward_seconds(SECONDS_PER_DAY * 10);
        
        // Suppose we've accrued 0.1% interest in CDP in these 10 days in CDP
        vault::accrue_interest_for_test<EUSDY>(smart_signer, echelon_mod_amount * 1 / 1000);

        // measure interest accrued via lending
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let mod_lending_bal = lending::shares_to_coins(mod_market_obj, shares);
        let lending_interest_accrued = mod_lending_bal - echelon_mod_amount;

        let (_, vault_liability_after) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let vault_interest_accrued = vault_liability_after - vault_liability;

        //
        // Deposit into USDY Treasury
        // 
        
        let withdrawable_usdy_before_deposit = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);

        let usdy_coin = coin::mint<USDY>(usdy_amount, &mint_cap);
        vault_scripts::deposit_usdy(user, usdy_coin, mod_market_obj, option::none());

        let (vault_collateral, vault_liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let echelon_mod_amount = lending::shares_to_coins(mod_market_obj, shares);

        assert!(vault_collateral == usdy_amount * 2, 0);

        // MOD borrowed as liability = Total amount of MOD supplied on Echelon - the interest amount
        // Interest & fees as liability = 1% vault_fee_amount accrued twice + 1x usdy_amount of interest accrued in the vault over 10 days
        // + 1 from rounding error
        assert!(vault_liability == echelon_mod_amount - lending_interest_accrued + vault_fee_amount * 2 + vault_interest_accrued + 1, 0);

        // Ensure we keep 105% CR
        assert!(vault_collateral / vault_liability == DEFAULT_CR / BPS_BASE, 0);

        // check we could withdraw 99% of what we put in (- 1% borrow fee) + 98.9% of previous amount (given interest accrued)
        let withdrawable_usdy = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);
        let echelon = 10000;

        assert!((withdrawable_usdy_before_deposit + usdy_amount - vault_fee_amount) - withdrawable_usdy < echelon, 0);

        // Clean up
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(manager = @0xBEEF, usdy_vault = @usdy_vault, user = @0xCAFE, mock_borrower = @0xDEAD)]
    public fun withdraw_usdy_cdp_ir_gt_lending_ir_ok(manager: &signer, usdy_vault: &signer, user: &signer, mock_borrower: &signer) {
        let (mint_cap, mod_market_obj, usdc_market_obj) = init_for_test(manager, usdy_vault);

        //
        // Deposit into USDY Treasury
        // 
        
        let usdy_amount = 10000000;
        let usdy_coin = coin::mint<USDY>(usdy_amount, &mint_cap);
        vault_scripts::deposit_usdy(user, usdy_coin, mod_market_obj, option::none());

        // fetch smart signer info
        let smart_signer_addr = vault_scripts::smart_signer_address(signer::address_of(user));
        let smart_signer = &vault_scripts::generate_smart_signer_for_test(signer::address_of(user));

        let (vault_collateral, vault_liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let echelon_mod_amount = lending::shares_to_coins(mod_market_obj, shares);

        assert!(vault_collateral == usdy_amount, 0);

        // MOD taken out + fee
        let vault_fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(vault::borrow_fee_ratio(), echelon_mod_amount));
        assert!(vault_liability == echelon_mod_amount + vault_fee_amount, 0);

        // Ensure we keep 105% CR
        assert!(vault_collateral / vault_liability == DEFAULT_CR / BPS_BASE, 0);

        //
        // Step forwards in time, accruing interest in CDP & lending
        // 
        
        mock_borrower_for_test(usdy_vault, mock_borrower, usdc_market_obj, mod_market_obj);

        // Fast forward 10 days for interest accrual on echelon
        timestamp::fast_forward_seconds(SECONDS_PER_DAY * 10);
        
        // Suppose we've accrued 0.1% interest in CDP in these 10 days in CDP
        vault::accrue_interest_for_test<EUSDY>(smart_signer, echelon_mod_amount * 1 / 1000);

        // measure interest accrued via lending
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let mod_lending_bal = lending::shares_to_coins(mod_market_obj, shares);
        let interest_accrued = mod_lending_bal - echelon_mod_amount;

        assert!(interest_accrued > 0, 0);

        //
        // Withdraw from USDY Treasury
        // 

        // max usdy to withdraw should be 98.9%
        let max_usdy_to_withdraw = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);

        // withdraw 98% of user's position (given we can't take max as CDP interest % > Echelon yield %)
        let (usdy_coin, extra_mod) = vault_scripts::withdraw_usdy(user, usdy_amount * 98 / 100, coin::zero<MOD>(), mod_market_obj, option::none());

        assert!(coin::value(&usdy_coin) == usdy_amount * 98 / 100, 0);
        assert!(vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj) == max_usdy_to_withdraw - usdy_amount * 98 / 100, 0);

        // Clean up
        coin::destroy_mint_cap(mint_cap);
        account::create_account_for_test(signer::address_of(user));
        coin::register<USDY>(user);
        coin::deposit<USDY>(signer::address_of(user), usdy_coin);
        mod_coin::burn(extra_mod);
    }

    #[test(manager = @0xBEEF, usdy_vault = @usdy_vault, user = @0xCAFE, mock_borrower = @0xDEAD)]
    public fun withdraw_usdy_cdp_ir_gt_lending_ir_extra_mod_full_close_ok(manager: &signer, usdy_vault: &signer, user: &signer, mock_borrower: &signer) {
        let (mint_cap, mod_market_obj, usdc_market_obj) = init_for_test(manager, usdy_vault);

        //
        // Deposit into USDY Treasury
        // 
        
        let usdy_amount = 10000000;
        let usdy_coin = coin::mint<USDY>(usdy_amount, &mint_cap);
        vault_scripts::deposit_usdy(user, usdy_coin, mod_market_obj, option::none());

        // fetch smart signer info
        let smart_signer_addr = vault_scripts::smart_signer_address(signer::address_of(user));
        let smart_signer = &vault_scripts::generate_smart_signer_for_test(signer::address_of(user));

        let (vault_collateral, vault_liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let echelon_mod_amount = lending::shares_to_coins(mod_market_obj, shares);

        assert!(vault_collateral == usdy_amount, 0);

        // MOD taken out + fee
        let vault_fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(vault::borrow_fee_ratio(), echelon_mod_amount));
        assert!(vault_liability == echelon_mod_amount + vault_fee_amount, 0);

        // Ensure we keep 105% CR
        assert!(vault_collateral / vault_liability == DEFAULT_CR / BPS_BASE, 0);

        //
        // Step forwards in time, accruing interest in CDP & lending
        // 
        
        mock_borrower_for_test(usdy_vault, mock_borrower, usdc_market_obj, mod_market_obj);

        // Fast forward 10 days for interest accrual on echelon
        timestamp::fast_forward_seconds(SECONDS_PER_DAY * 10);
        
        // Suppose we've accrued 0.1% interest in CDP in these 10 days in CDP
        vault::accrue_interest_for_test<EUSDY>(smart_signer, echelon_mod_amount * 1 / 100);

        // measure interest accrued via lending
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let mod_lending_bal = lending::shares_to_coins(mod_market_obj, shares);
        let interest_accrued = mod_lending_bal - echelon_mod_amount;

        assert!(interest_accrued > 0, 0);

        //
        // Withdraw from USDY Treasury
        // 

        // max usdy to withdraw should be 98.9%
        let max_usdy_to_withdraw = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);

        // withdraw all of user's position (using extra_mod_coin to cover the extra mod needed)
        let additional_mod = mod_coin::mint(181895);
        let (usdy_coin, extra_mod) = vault_scripts::withdraw_usdy(user, usdy_amount, additional_mod, mod_market_obj, option::none());

        assert!(coin::value(&extra_mod) == 0, 0);
        assert!(coin::value(&usdy_coin) == usdy_amount, 0);
        assert!(vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj) == 0, 0);

        // Clean up
        coin::destroy_mint_cap(mint_cap);
        account::create_account_for_test(signer::address_of(user));
        coin::register<USDY>(user);
        coin::deposit<USDY>(signer::address_of(user), usdy_coin);
        mod_coin::burn(extra_mod);
    }

    #[test(manager = @0xBEEF, usdy_vault = @usdy_vault, user = @0xCAFE, mock_borrower = @0xDEAD)]
    public fun withdraw_usdy_cdp_ir_gt_lending_ir_extra_mod_not_full_close_ok(manager: &signer, usdy_vault: &signer, user: &signer, mock_borrower: &signer) {
        let (mint_cap, mod_market_obj, usdc_market_obj) = init_for_test(manager, usdy_vault);

        //
        // Deposit into USDY Treasury
        // 
        
        let usdy_amount = 10000000;
        let usdy_coin = coin::mint<USDY>(usdy_amount, &mint_cap);
        vault_scripts::deposit_usdy(user, usdy_coin, mod_market_obj, option::none());

        // fetch smart signer info
        let smart_signer_addr = vault_scripts::smart_signer_address(signer::address_of(user));
        let smart_signer = &vault_scripts::generate_smart_signer_for_test(signer::address_of(user));

        let (vault_collateral, vault_liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let echelon_mod_amount = lending::shares_to_coins(mod_market_obj, shares);

        assert!(vault_collateral == usdy_amount, 0);

        // MOD taken out + fee
        let vault_fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(vault::borrow_fee_ratio(), echelon_mod_amount));
        assert!(vault_liability == echelon_mod_amount + vault_fee_amount, 0);

        // Ensure we keep 105% CR
        assert!(vault_collateral / vault_liability == DEFAULT_CR / BPS_BASE, 0);

        //
        // Step forwards in time, accruing interest in CDP & lending
        // 
        
        mock_borrower_for_test(usdy_vault, mock_borrower, usdc_market_obj, mod_market_obj);

        // Fast forward 10 days for interest accrual on echelon
        timestamp::fast_forward_seconds(SECONDS_PER_DAY * 10);
        
        // Suppose we've accrued 0.1% interest in CDP in these 10 days in CDP
        vault::accrue_interest_for_test<EUSDY>(smart_signer, echelon_mod_amount * 1 / 100);

        // measure interest accrued via lending
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let mod_lending_bal = lending::shares_to_coins(mod_market_obj, shares);
        let interest_accrued = mod_lending_bal - echelon_mod_amount;

        assert!(interest_accrued > 0, 0);

        //
        // Withdraw from USDY Treasury
        // 

        // max usdy to withdraw should be 98.9%
        let max_usdy_to_withdraw = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);

        // withdraw almost all of user's position (using extra_mod_coin to cover the extra mod needed)
        let additional_mod = mod_coin::mint(181895);
        let (usdy_coin, extra_mod) = vault_scripts::withdraw_usdy(user, usdy_amount - 10000, additional_mod, mod_market_obj, option::none());

        // extra mod left over from helping close the position
        assert!(coin::value(&extra_mod) == 9523, 0);
        assert!(coin::value(&usdy_coin) == usdy_amount - 10000, 0);

        // close out the cdp position despite having already emptied the whole of the lending position
        let (usdy_coin2, extra_mod2) = vault_scripts::withdraw_usdy(user, 10000, extra_mod, mod_market_obj, option::none());

        assert!(coin::value(&extra_mod2) == 0, 0);
        assert!(coin::value(&usdy_coin2) == 10000, 0);
        assert!(vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj) == 0, 0);

        // Clean up
        coin::destroy_mint_cap(mint_cap);
        account::create_account_for_test(signer::address_of(user));
        coin::register<USDY>(user);
        coin::deposit<USDY>(signer::address_of(user), usdy_coin);
        coin::deposit<USDY>(signer::address_of(user), usdy_coin2);
        mod_coin::burn(extra_mod2);
    }

    #[test(manager = @0xBEEF, usdy_vault = @usdy_vault, user = @0xCAFE, mock_borrower = @0xDEAD)]
    public fun withdraw_usdy_lending_ir_gt_cdp_ir_ok(manager: &signer, usdy_vault: &signer, user: &signer, mock_borrower: &signer) {
        let (mint_cap, mod_market_obj, usdc_market_obj) = init_for_test(manager, usdy_vault);

        //
        // Deposit into USDY Treasury
        // 
        
        let usdy_amount = 10000000;
        let usdy_coin = coin::mint<USDY>(usdy_amount, &mint_cap);
        vault_scripts::deposit_usdy(user, usdy_coin, mod_market_obj, option::none());

        // fetch smart signer info
        let smart_signer_addr = vault_scripts::smart_signer_address(signer::address_of(user));
        let smart_signer = &vault_scripts::generate_smart_signer_for_test(signer::address_of(user));

        let (vault_collateral, vault_liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let echelon_mod_amount = lending::shares_to_coins(mod_market_obj, shares);

        assert!(vault_collateral == usdy_amount, 0);

        // MOD taken out + fee
        let vault_fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(vault::borrow_fee_ratio(), echelon_mod_amount));
        assert!(vault_liability == echelon_mod_amount + vault_fee_amount, 0);

        // Ensure we keep 105% CR
        assert!(vault_collateral / vault_liability == DEFAULT_CR / BPS_BASE, 0);

        //
        // Step forwards in time, accruing interest in CDP & lending
        // 
        
        mock_borrower_for_test(usdy_vault, mock_borrower, usdc_market_obj, mod_market_obj);

        // Fast forward 100 days for interest accrual on echelon
        timestamp::fast_forward_seconds(SECONDS_PER_DAY * 200);
        
        // Suppose we've accrued 0.01% interest in CDP in these 200 days in CDP
        vault::accrue_interest_for_test<EUSDY>(smart_signer, echelon_mod_amount * 1 / 10000);

        // measure interest accrued via lending
        let shares = lending::account_shares(smart_signer_addr, mod_market_obj);
        let mod_lending_bal = lending::shares_to_coins(mod_market_obj, shares);
        let interest_accrued = mod_lending_bal - echelon_mod_amount;

        assert!(interest_accrued > 0, 0);

        //
        // Withdraw from USDY Treasury
        // 

        // max usdy to withdraw should be 103%
        let max_usdy_to_withdraw = vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj);

        // withdraw 100% of user's position (given we can take max as CDP interest % < Echelon yield %)
        let (usdy_coin, extra_mod) = vault_scripts::withdraw_usdy(user, usdy_amount, coin::zero<MOD>(), mod_market_obj, option::none());
        
        // extra_mod == profit from lending - interest paid in CDP
        assert!(coin::value(&extra_mod) == 36501, 0);
        assert!(coin::value(&usdy_coin) == usdy_amount, 0);
        assert!(vault_scripts::withdrawable_usdy(signer::address_of(user), mod_market_obj) == max_usdy_to_withdraw - usdy_amount, 0);

        let (collateral, liability) = vault::account_collateral_and_liability_amounts<EUSDY>(smart_signer_addr);
        let withdrawable_mod = lending::account_withdrawable_coins(smart_signer_addr, mod_market_obj);

        assert!(collateral == 0, 0);
        assert!(liability == 0, 0);
        assert!(withdrawable_mod == 1, 0);

        // Clean up
        coin::destroy_mint_cap(mint_cap);
        account::create_account_for_test(signer::address_of(user));
        coin::register<USDY>(user);
        coin::deposit<USDY>(signer::address_of(user), usdy_coin);
        mod_coin::burn(extra_mod);
    }

    // TODO: WRITE A DEPOSIT -> WITHDRAW -> DEPOSIT -> WITHDRAW TEST
}