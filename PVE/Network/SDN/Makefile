SOURCES=Plugin.pm VnetPlugin.pm VlanPlugin.pm VxlanPlugin.pm FrrPlugin.pm FaucetPlugin.pm OVSFaucetPlugin.pm EvpnPlugin.pm


PERL5DIR=${DESTDIR}/usr/share/perl5

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${PERL5DIR}/PVE/Network/SDN/$$i; done

