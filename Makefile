include /usr/share/dpkg/pkg-info.mk

PACKAGE=libpve-network-perl

BUILDDIR ?= $(PACKAGE)-$(DEB_VERSION_UPSTREAM)

DEB=$(PACKAGE)_$(DEB_VERSION_UPSTREAM_REVISION)_all.deb
DSC=$(PACKAGE)_$(DEB_VERSION_UPSTREAM_REVISION).dsc
TARGZ=$(PACKAGE)_$(PKGVER)-$(PKGREL).tar.gz

all:
	$(MAKE) -C PVE

.PHONY: dinstall
dinstall: deb
	dpkg -i $(DEB)

$(BUILDDIR): PVE debian
	rm -rf $(BUILDDIR)
	rsync -a * $(BUILDDIR)
	echo "git clone git://git.proxmox.com/git/pve-network.git\\ngit checkout $(shell git rev-parse HEAD)" > $(BUILDDIR)/debian/SOURCE

.PHONY: deb
deb: $(DEB)
$(DEB): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -b -us -uc
	lintian $(DEB)

.PHONY: dsc
dsc $(TARGZ): $(DSC)
$(DSC): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -S -us -uc -d -nc
	lintian $(DSC)

.PHONY: clean distclean
distclean: clean
clean:
	rm -rf *~ *.deb *.changes $(PACKAGE)-* *.buildinfo *.dsc *.tar.gz

.PHONY: test
test:
	$(MAKE) -C test

.PHONY: install
install:
	$(MAKE) -C PVE install

.PHONY: upload
upload: $(DEB)
	tar cf - $(DEB)|ssh -X repoman@repo.proxmox.com -- upload --product pve --dist bullseye
