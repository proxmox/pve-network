PACKAGE=libpve-network-perl
PKGVER != dpkg-parsechangelog -Sversion | cut -d- -f1
PKGREL != dpkg-parsechangelog -Sversion | cut -d- -f2

ARCH=all

BUILDDIR ?= ${PACKAGE}-${PKGVER}

DEB=${PACKAGE}_${PKGVER}-${PKGREL}_${ARCH}.deb
DSC=${PACKAGE}_${PKGVER}-${PKGREL}.dsc
TARGZ=${PACKAGE}_${PKGVER}-${PKGREL}.tar.gz

all:
	${MAKE} -C PVE

.PHONY: dinstall
dinstall: deb
	dpkg -i ${DEB}

${BUILDDIR}: PVE debian
	rm -rf ${BUILDDIR}
	rsync -a * ${BUILDDIR}
	echo "git clone git://git.proxmox.com/git/pve-network.git\\ngit checkout $(shell git rev-parse HEAD)" > ${BUILDDIR}/debian/SOURCE

.PHONY: deb
deb: ${DEB}
${DEB}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -b -us -uc
	lintian ${DEB}

.PHONY: dsc
dsc ${TARGZ}: ${DSC}
${DSC}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -S -us -uc -d -nc
	lintian ${DSC}

.PHONY: clean distclean
distclean: clean
clean:
	rm -rf *~ *.deb *.changes ${PACKAGE}-* *.buildinfo *.dsc *.tar.gz

.PHONY: check
check:
	$(MAKE) -C test check

.PHONY: install
install:
	${MAKE} -C PVE install

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB}|ssh -X repoman@repo.proxmox.com -- upload --product pve --dist stretch

