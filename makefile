test_all:
	forge test -vv --match-contract Test --fork-url https://eth-mainnet.g.alchemy.com/v2/38A3rlBUZpErpHxQnoZlEhpRHSu4a7VB --fork-block-number 19955703

test_put:
	forge test -vv --match-contract PutETHTest --fork-url https://eth-mainnet.g.alchemy.com/v2/38A3rlBUZpErpHxQnoZlEhpRHSu4a7VB --fork-block-number 19955703

test_call:
	forge test -vv --match-contract CallETHTest --fork-url https://eth-mainnet.g.alchemy.com/v2/38A3rlBUZpErpHxQnoZlEhpRHSu4a7VB --fork-block-number 19955703 
t:
	forge test -vv --match-contract PutETHTest --fork-url https://eth-mainnet.g.alchemy.com/v2/38A3rlBUZpErpHxQnoZlEhpRHSu4a7VB --fork-block-number 19955703 --match-test test_synthetix_perp_operations

spell:
	cspell "**/*.*"