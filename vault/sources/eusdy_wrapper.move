module usdy_vault::eusdy_wrapper {
    use std::signer;
    use std::string;

    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability, FreezeCapability};

    use usdy_vault::package;

    use usdy_alias::usdy_coin::{USDY};

    struct EUSDY {}

    struct Capabilities has key {
        burn_capability: BurnCapability<EUSDY>,
        freeze_capability: FreezeCapability<EUSDY>,
        mint_capability: MintCapability<EUSDY>,
    }

    // Errors
    const ERR_UNAUTHORIZED: u64 = 0;
    const ERR_PACKAGE_UNINITIALIZED: u64 = 1;

   public entry fun initialize(deployer: &signer) {
        assert!(signer::address_of(deployer) == @usdy_vault_deployer, ERR_UNAUTHORIZED);

        // Key dependencies
        assert!(package::initialized(), ERR_PACKAGE_UNINITIALIZED);

        let resource_account_signer = package::package_signer();
        let (burn_capability, freeze_capability, mint_capability) = coin::initialize<EUSDY>(
            &resource_account_signer,
            string::utf8(b"Echelon USDY"),
            string::utf8(b"eUSDY"),
            6,
            true,
        );

        // register the USDY coin to the resource account signer as we store USDY at account address
        coin::register<USDY>(&resource_account_signer);

        move_to(&resource_account_signer, Capabilities { burn_capability, freeze_capability, mint_capability });
    }

    public entry fun mint_for_testnet(user: &signer, amount: u64) acquires Capabilities {
        let caps = borrow_global_mut<Capabilities>(package::package_address());

        let eusdy_coin = coin::mint<EUSDY>(amount, &caps.mint_capability);

        coin::deposit<EUSDY>(signer::address_of(user), eusdy_coin);
    }


    public fun mint_eusdy(usdy_coin: Coin<USDY>): Coin<EUSDY> acquires Capabilities {
        let caps = borrow_global_mut<Capabilities>(package::package_address());

        let usdy_amount = coin::value(&usdy_coin);

        let eusdy_coin = coin::mint<EUSDY>(usdy_amount, &caps.mint_capability);

        coin::deposit<USDY>(package::package_address(), usdy_coin);

        eusdy_coin
    }   

    public fun burn_eusdy(eusdy_coin: Coin<EUSDY>): Coin<USDY> acquires Capabilities{
        let caps = borrow_global_mut<Capabilities>(package::package_address());

        let eusdy_amount = coin::value(&eusdy_coin);

        coin::burn<EUSDY>(eusdy_coin, &caps.burn_capability);

        let usdy_coin = coin::withdraw<USDY>(&package::package_signer(), eusdy_amount);

        usdy_coin
    }   

    #[test_only]
    use usdy_alias::usdy_coin::{Self};

    #[test_only]
    public fun init_for_test(): MintCapability<USDY> {
        let deployer = aptos_framework::account::create_signer_for_test(@usdy_vault_deployer);

        package::init_for_test();
        let mint_cap = usdy_coin::init_for_test();

        initialize(&deployer);

        mint_cap
    }

    #[test]
    public fun mint_ok() acquires Capabilities {
        let usdy_mint_cap = init_for_test();

        let coin_amount = 1000000000;
        let usdy_coin = coin::mint<USDY>(coin_amount, &usdy_mint_cap);

        let eusdy_coin = mint_eusdy(usdy_coin);

        assert!(coin_amount == coin::value(&eusdy_coin), 0);
        assert!(coin::balance<USDY>(package::package_address()) == coin_amount, 0);

        // Cleanup
        coin::register<EUSDY>(&package::package_signer());
        coin::deposit<EUSDY>(package::package_address(), eusdy_coin);
        coin::destroy_mint_cap(usdy_mint_cap);
    }

    #[test]
    public fun burn_ok() acquires Capabilities {
        let usdy_mint_cap = init_for_test();

        let coin_amount = 1000000000;
        let usdy_coin = coin::mint<USDY>(coin_amount, &usdy_mint_cap);


        let eusdy_coin = mint_eusdy(usdy_coin);

        assert!(coin_amount == coin::value(&eusdy_coin), 0);
        assert!(coin::balance<USDY>(package::package_address()) == coin_amount, 0);

        let usdy_coin = burn_eusdy(eusdy_coin);

        assert!(coin::value(&usdy_coin) == coin_amount, 0);
        assert!(coin::balance<USDY>(package::package_address()) == 0, 0);

        // Cleanup
        coin::deposit<USDY>(package::package_address(), usdy_coin);
        coin::destroy_mint_cap(usdy_mint_cap);
    }
}
