PREFIX = 
BINDIR = $(PREFIX)/usr/bin
MANDIR = $(PREFIX)/usr/man
SBINDIR = $(PREFIX)/usr/sbin
XBINDIR = $(PREFIX)/usr/X11R6/bin
URPMIDIR = $(PREFIX)/var/lib/urpmi
URPMIDIR2 = $(PREFIX)/etc/urpmi
LOCALEDIR = $(PREFIX)/usr/share/locale


.PHONY: install clean

install: autoirpm.update-all
	$(MAKE) -C po $@
	install -d $(BINDIR) $(SBINDIR) $(XBINDIR) $(URPMIDIR) $(URPMIDIR2) $(MANDIR)/man8
	install -m 4755 urpmi $(BINDIR)
	install _irpm rpm-find-leaves $(BINDIR)
	install -m 644 autoirpm.deny $(URPMIDIR2)
	for i in *.8; do bzip2 -c $$i > $(MANDIR)/man8/$$i.bz2 ; done
	install urpmi.addmedia autoirpm.update autoirpm.uninstall $(SBINDIR)
	install -s autoirpm.update-all $(SBINDIR)
	ln -sf urpmi.addmedia $(SBINDIR)/urpmi.removemedia
	ln -sf urpmi.addmedia $(SBINDIR)/urpmi.update
	install gurpmi $(XBINDIR)

autoirpm.update-all: %: %.cc
	$(CXX) -I/usr/include/rpm -g $< -lrpm -ldb1 -lz -o $@

tar: clean
	cd .. ; tar cfy urpmi.tar.bz2 urpmi

po:
	$(MAKE) -C $@

clean:
	$(MAKE) -C po $@
	rm -f *~ autoirpm.update-all
