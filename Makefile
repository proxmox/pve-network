include /usr/share/dpkg/pkg-info.mk

PACKAGE=libpve-network-perl

BUILDDIR ?= $(PACKAGE)-$(DEB_VERSION_UPSTREAM)

DEBS=\
      $(PACKAGE)_$(DEB_VERSION_UPSTREAM_REVISION)_all.deb \
      libpve-network-api-perl_$(DEB_VERSION_UPSTREAM_REVISION)_all.deb \

DSC=$(PACKAGE)_$(DEB_VERSION_UPSTREAM_REVISION).dsc

all: deb

.PHONY: tidy
tidy:
	git ls-files ':*.p[ml]'| xargs -n4 -P0 proxmox-perltidy

.PHONY: dinstall
dinstall: deb
	dpkg -i $(DEBS)

$(BUILDDIR): src debian
	rm -rf $@ $@.tmp
	cp -a src $@.tmp
	cp -a debian $@.tmp/
	echo "git clone git://git.proxmox.com/git/pve-network.git\\ngit checkout $(shell git rev-parse HEAD)" > $@.tmp/debian/SOURCE
	mv $@.tmp $@

.PHONY: deb
deb: $(DEBS)
$(DEBS) &: $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -b -us -uc
	lintian $(DEBS)

.PHONY: dsc
dsc: clean
	$(MAKE) $(DSC)
	lintian $(DSC)

$(DSC): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -S -us -uc -d

sbuild: $(DSC)
	sbuild $(DSC)

.PHONY: clean distclean
distclean: clean
clean:
	rm -rf *~ *.deb *.changes $(PACKAGE)-[0-9]*/ $(PACKAGE)*.tar* *.build *.buildinfo *.dsc

.PHONY: upload
upload: UPLOAD_DIST ?= $(DEB_DISTRIBUTION)
upload: $(DEBS)
	tar cf - $(DEBS)|ssh -X repoman@repo.proxmox.com -- upload --product pve --dist $(UPLOAD_DIST)
