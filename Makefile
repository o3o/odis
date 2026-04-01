.PHONY: check test tags format doc

check:
	odin check . -no-entry-point

strict:
	odin check . -no-entry-point -strict-style -vet

test:
	odin test .

tags:
	@otags -o tags .

format:
	odinfmt -w .
doc:
	odin doc . 
