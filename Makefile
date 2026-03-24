.PHONY: check test tags format doc

check:
	odin check . -no-entry-point

test:
	odin test .

tags:
	@otags -o tags .

format:
	odinfmt -w .
doc:
	odin doc . 
