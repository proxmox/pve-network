SERVICEDIR=$(DESTDIR)/lib/systemd/system

all:
	@true

.PHONY: install
install:
	install -d $(SERVICEDIR)
	install -d $(SERVICEDIR)/dnsmasq@.service.d
	install -t $(SERVICEDIR)/dnsmasq@.service.d -m 0644 00-dnsmasq-after-networking.conf

.PHONY: clean
clean:
	@true
