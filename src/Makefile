all:
	$(MAKE) -C PVE

.PHONY: clean
clean:
	$(MAKE) -C test $@
	$(MAKE) -C PVE $@

.PHONY: test
test:
	$(MAKE) -C $@

.PHONY: install
install:
	$(MAKE) -C PVE $@
