SOURCES=Vnet.pm Transport.pm


PERL5DIR=${DESTDIR}/usr/share/perl5

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${PERL5DIR}/PVE/Network/$$i; done
	make -C Vnet install
	make -C Transport install
