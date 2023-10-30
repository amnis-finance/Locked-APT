# Running tests
aptos move test --named-addresses locked_apt=0xdollar,deployer=0xdollar,admin=0xdollar,amnis=0xdollar

# Deploy instructions
1. Make sure there's an Aptos profile created for the correct network (devnet/testnet/mainnet).
2.The seed can be changed to generate a different resource account address if multiple test deploys are needed.
aptos move create-resource-account-and-publish-package --named-addresses amnis=0xb8188ed9a1b56a11344aab853f708ead152484081c3b5ec081c38646500c42d7,deployer=amnislock,admin=amnislock --seed 1 --address-name locked_apt --profile amnislock

