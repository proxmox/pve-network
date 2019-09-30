SOURCES=Plugin.pm VnetPlugin.pm VlanPlugin.pm VxlanPlugin.pm FaucetControllerPlugin.pm FaucetPlugin.pm EvpnPlugin.pm EvpnControllerPlugin.pm QinQPlugin.pm


PERL5DIR=${DESTDIR}/usr/share/perl5

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${PERL5DIR}/PVE/Network/SDN/$$i; done

