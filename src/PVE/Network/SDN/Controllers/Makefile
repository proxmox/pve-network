SOURCES=Plugin.pm FaucetPlugin.pm EvpnPlugin.pm BgpPlugin.pm IsisPlugin.pm


PERL5DIR=${DESTDIR}/usr/share/perl5

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${PERL5DIR}/PVE/Network/SDN/Controllers/$$i; done
