/// A mock thala protocol vault implementation for tests. Non-test-only interfaces are consistent with the real thala oracle.
/// This package will not be deployed
module thala_protocol_interface::vault {
    use std::option::{Option};
    use std::signer;

    use aptos_std::math64;
    use aptos_framework::coin::{Self, Coin};

    use fixed_point64::fixed_point64::{Self, FixedPoint64};

    use thala_protocol_interface::mod_coin::{Self, MOD};

    struct Vault<phantom CoinType> has key {
        account_address: address,

        collateral: Coin<CoinType>,
        debt: u64,
        interest: u64,
    }

    // Constants
    const BPS_BASE: u64 = 10000;
    const DEFAULT_MCR: u64 = 10500; // 105% CR

   // Vault States
    const ERR_VAULT_OPENED_VAULT: u64 = 5;
    const ERR_VAULT_UNOPENED_VAULT: u64 = 6;
    const ERR_VAULT_EXCEEDED_LIABILITY_AMOUNT: u64 = 9;
    const ERR_VAULT_OVERWITHDRAW: u64 = 13;

    public fun open_vault<CoinType>(account: &signer, collateral: Coin<CoinType>, borrow_amount: u64, hint: Option<address>): Coin<MOD>
    acquires Vault {
        let account_addr = signer::address_of(account);
        assert!(!opened_vault<CoinType>(account_addr), ERR_VAULT_OPENED_VAULT);

        move_to(account, Vault<CoinType> {
            account_address: account_addr,
            collateral: coin::zero(),
            debt: 0,
            interest: 0,
        });

        deposit_collateral<CoinType>(account, collateral, hint);
        borrow<CoinType>(account, borrow_amount, hint)
    }

    /// Deposit additional collateral into a vault
    public fun deposit_collateral<CoinType>(account: &signer, collateral: Coin<CoinType>, hint: Option<address>)
    acquires Vault {
        let account_addr = signer::address_of(account);
        assert!(opened_vault<CoinType>(account_addr), ERR_VAULT_UNOPENED_VAULT);

        let vault = borrow_global_mut<Vault<CoinType>>(account_addr);

        // deposit the collateral into the vault
        let amount = coin::value(&collateral);
        coin::merge(&mut vault.collateral, collateral);
    }

    /// Extract collateral from a vault. MCR is maintained
    public fun withdraw_collateral<CoinType>(account: &signer, amount: u64, hint: Option<address>): Coin<CoinType>
    acquires Vault {
        let account_addr = signer::address_of(account);
        assert!(opened_vault<CoinType>(account_addr), ERR_VAULT_UNOPENED_VAULT);

        let vault = borrow_global_mut<Vault<CoinType>>(account_addr);

        let (collateral_amount, liability_amount) = vault_collateral_and_liability_amounts(vault);

        assert!(amount <= collateral_amount, ERR_VAULT_OVERWITHDRAW);

        // extract and update state
        if (amount == 0) {
            return coin::zero()
        };

        // extract & update vault totals
        let collateral = coin::extract<CoinType>(&mut vault.collateral, amount);

        let (collateral_amount, liability_amount) = vault_collateral_and_liability_amounts(vault);

        // enforce minimum CR
        assert!(liability_amount == 0 || DEFAULT_MCR / BPS_BASE <= collateral_amount / liability_amount, 0);

        collateral
    }

    /// Create additional debt against the collateral in the vault
    public fun borrow<CoinType>(account: &signer, amount: u64, hint: Option<address>): Coin<MOD> acquires Vault {
        let account_addr = signer::address_of(account);
        assert!(opened_vault<CoinType>(account_addr), ERR_VAULT_UNOPENED_VAULT);

        if (amount == 0) {
            return coin::zero()
        };

        let vault = borrow_global_mut<Vault<CoinType>>(account_addr);

        let fee_amount = fixed_point64::decode_round_up(fixed_point64::mul(borrow_fee_ratio(), amount));
        let increased_liability = amount + fee_amount;

        // create debt (including the fee)
        let debt = mod_coin::mint(increased_liability);
        let prev_vault_debt = vault.debt;
        vault.debt = vault.debt + increased_liability;

        mod_coin::burn(coin::extract(&mut debt, fee_amount));

        debt
    }

    /// Repay debt to the vault
    public fun repay<CoinType>(account: &signer, debt: Coin<MOD>, hint: Option<address>) acquires Vault {
        let account_addr = signer::address_of(account);
        assert!(opened_vault<CoinType>(account_addr), ERR_VAULT_UNOPENED_VAULT);

        // update vault liability
        let vault = borrow_global_mut<Vault<CoinType>>(account_addr);
        let prev_vault_debt = vault.debt;

        let repay_amount = coin::value(&debt);
        let liability_amount = vault.debt + vault.interest;
        assert!(repay_amount <= liability_amount, ERR_VAULT_EXCEEDED_LIABILITY_AMOUNT);

        let amount = coin::value(&debt);

        if (amount == 0) {
            coin::destroy_zero(debt);
            return
        };

        // Calculate interest/debt repay amounts. Interest is repaid first
        let repay_interest_amount = math64::min(vault.interest, amount);
        let repay_debt_amount = amount - repay_interest_amount;

        // update state
        vault.interest = vault.interest - repay_interest_amount;
        vault.debt = vault.debt - repay_debt_amount;

        // absorb interest and burn the remaining repaid debt
        mod_coin::burn(coin::extract(&mut debt, repay_interest_amount));
        mod_coin::burn(debt);
    }

    #[view]
    public fun opened_vault<CoinType>(account_addr: address): bool {
        exists<Vault<CoinType>>(account_addr)
    }

    #[view]
    public fun account_collateral_and_liability_amounts<CoinType>(account_addr: address): (u64, u64) acquires Vault {
        assert!(opened_vault<CoinType>(account_addr), ERR_VAULT_UNOPENED_VAULT);
        let vault = borrow_global_mut<Vault<CoinType>>(account_addr);

        (coin::value(&vault.collateral), vault.debt + vault.interest)
    }

    fun vault_collateral_and_liability_amounts<CoinType>(vault: &Vault<CoinType>): (u64, u64) {
        (coin::value(&vault.collateral), vault.debt + vault.interest)
    }

    #[view]
    public fun borrow_fee_ratio(): FixedPoint64 {
        // Hardcoded fee ratio to 1% for interface simplicity
        fixed_point64::fraction(1, 100)
    }

    // This method is used to simulate the accrual of interest in the vault over time
    #[test_only]
    public fun accrue_interest_for_test<CoinType>(account: &signer, new_interest: u64) acquires Vault {
        let account_addr = signer::address_of(account);
        let vault = borrow_global_mut<Vault<CoinType>>(account_addr);
        vault.interest = vault.interest + new_interest;
    }
}