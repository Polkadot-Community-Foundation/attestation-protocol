.PHONY: install build test deploy clean

install :
	forge install
	bun install

build :
	forge build

test :
	forge test -vv

deploy : build
	bun run deploy

clean :
	forge clean
