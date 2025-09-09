module usdy_alias::usdy_coin {
    use std::signer;
    use std::string;

    use aptos_framework::type_info;
    use aptos_framework::coin;

    struct USDY {}

    public entry fun init_testnet(deployer: &signer) {
        let name = string::utf8(type_info::struct_name(&type_info::type_of<USDY>()));
        let symbol = string::utf8(b"USDY");
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<USDY>(deployer, name, symbol, 8, false);
        
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);

        coin::register<USDY>(deployer);

        coin::deposit(signer::address_of(deployer), coin::mint(100000000000000, &mint_cap));

        coin::destroy_mint_cap(mint_cap);
    }


    #[test_only]
    use aptos_framework::coin::{MintCapability};

    #[test_only]
    public fun init_for_test(): MintCapability<USDY> {
        let deployer = aptos_framework::account::create_signer_for_test(@usdy_alias);

        let name = string::utf8(type_info::struct_name(&type_info::type_of<USDY>()));
        let symbol = string::utf8(b"USDY");
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<USDY>(&deployer, name, symbol, 6, false);
        
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);

        mint_cap
    }
}
