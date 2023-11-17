SOURCES=Vnets.pm VnetPlugin.pm Zones.pm Controllers.pm Subnets.pm SubnetPlugin.pm Ipams.pm Dns.pm Dhcp.pm


PERL5DIR=${DESTDIR}/usr/share/perl5

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${PERL5DIR}/PVE/Network/SDN/$$i; done
	make -C Controllers install
	make -C Zones install
	make -C Ipams install
	make -C Dns install
	make -C Dhcp install

