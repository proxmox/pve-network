SOURCES=Fabric.pm FabricNode.pm Node.pm


PERL5DIR=${DESTDIR}/usr/share/perl5

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${PERL5DIR}/PVE/API2/Network/SDN/Fabrics/$$i; done
