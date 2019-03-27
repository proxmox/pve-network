SOURCES=Plugin.pm VlanPlugin.pm Vnet.pm VxlanMulticastPlugin.pm
.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${DESTDIR}${PERLDIR}/PVE/Network/$$i; done
