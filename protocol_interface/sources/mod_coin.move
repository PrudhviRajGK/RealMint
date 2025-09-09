/// A mock mod coin implementation for tests. Non-test-only interfaces are consistent with the real thala oracle.
/// This version of the package will not be deployed in production
module thala_protocol_interface::mod_coin {
    use std::string;
    use std::signer;

    use aptos_framework::coin::{Self, Coin, BurnCapability, FreezeCapability, MintCapability};

    ///
    /// Errors
    ///

    const ERR_UNAUTHORIZED: u64 = 0;

    // Initialization
    const ERR_MOD_COIN_UNINITIALIZED: u64 = 1;
    const ERR_MOD_COIN_INITIALIZED: u64 = 2;

    ///
    /// Resources
    ///

    /// MOD CoinType
    struct MOD {}

    struct Capabilities has key {
        burn_capability: BurnCapability<MOD>,
        freeze_capability: FreezeCapability<MOD>,
        mint_capability: MintCapability<MOD>,
    }

    ///
    /// Initialization
    ///

    public fun initialize(account: &signer) {
        assert!(signer::address_of(account) == @thala_protocol_interface, ERR_MOD_COIN_INITIALIZED);

        assert!(!initialized(), ERR_MOD_COIN_INITIALIZED);

        let name = string::utf8(b"Move Dollar");
        let symbol = string::utf8(b"MOD");
        let decimals = 8;

        let (burn_capability, freeze_capability, mint_capability) =
            coin::initialize<MOD>(account, name, symbol, decimals, false);

        move_to(account, Capabilities { burn_capability, freeze_capability, mint_capability });
    }

    ///
    /// Functions
    ///

    public fun mint(amount: u64): Coin<MOD> acquires Capabilities {
        assert!(initialized(), ERR_MOD_COIN_UNINITIALIZED);

        let cap = borrow_global<Capabilities>(@thala_protocol_interface);
        coin::mint(amount, &cap.mint_capability)
    }

    public fun burn(mod: Coin<MOD>) acquires Capabilities {
        assert!(initialized(), ERR_MOD_COIN_UNINITIALIZED);

        let cap = borrow_global<Capabilities>(@thala_protocol_interface);
        // if the coin's value == 0, we destroy the coin. Otherwise, we burn it.
        if (coin::value(&mod) == 0) {
            coin::destroy_zero(mod);
        } else {
            coin::burn(mod, &cap.burn_capability);
        };
    }

    // Public Getters

    public fun initialized(): bool {
        exists<Capabilities>(@thala_protocol_interface)
    }

    // Public Test Helpers

    #[test_only]
    public fun initialize_for_test() {
        let deployer = aptos_framework::account::create_signer_for_test(@thala_protocol_interface);
        initialize(&deployer);
    }

    #[test_only]
    public fun mint_for_test(amount: u64): Coin<MOD> acquires Capabilities {
        mint(amount)
    }

    #[test_only]
    public fun burn_for_test(mod: Coin<MOD>) acquires Capabilities {
        burn(mod);
    }

    #[test]
    fun initialize_ok() {
        let deployer = aptos_framework::account::create_signer_for_test(@thala_protocol_interface);
        initialize(&deployer);
        assert!(initialized(), 0);
    }
}
