PREFIX = 
BINDIR = $(PREFIX)/usr/bin
MANDIR = $(PREFIX)/usr/man
SBINDIR = $(PREFIX)/usr/sbin
URPMIDIR = $(PREFIX)/var/lib/urpmi
URPMIDIR2 = $(PREFIX)/etc/urpmi
LOCALEDIR = $(PREFIX)/usr/share/locale
CFLAGS = -Wall -g
LIBRPM = -lrpm -lrpmio -lrpmdb -lz -lbz2 -I/usr/include/rpm -lpopt
RPM=$(HOME)/rpm

NAME = urpmi
TAR = $(NAME).tar.bz2
LOG = $(NAME).logrotate

.PHONY: install clean rpm test

install:
	$(MAKE) -C po $@
	install -d $(BINDIR) $(SBINDIR) $(URPMIDIR) $(URPMIDIR2) $(MANDIR)/man5 $(MANDIR)/man8
	install urpmq $(BINDIR)
	install rpm-find-leaves urpmf $(BINDIR)
#	install -m 644 autoirpm.deny $(URPMIDIR2)
	install -m 644 skip.list $(URPMIDIR2)
	install -m 644 man/C/urpm*.5 $(MANDIR)/man5
	install -m 644 man/C/urpm*.8 $(MANDIR)/man8
	install urpmi urpme urpmi.addmedia urpmi.update urpmi.removemedia $(SBINDIR)
#	install -s autoirpm.update-all $(SBINDIR)
#	ln -sf urpmi.addmedia $(SBINDIR)/urpmi.removemedia
#	ln -sf urpmi.addmedia $(SBINDIR)/urpmi.update
	install gurpmi $(SBINDIR)
	ln -s -f ../../usr/bin/consolehelper $(BINDIR)/gurpmi
	for i in man/??* ; \
		do install -d $(MANDIR)/`basename $$i`/man8 ; \
		install -m 644 $$i/urpm*.8 $(MANDIR)/`basename $$i`/man8 ; \
	done	

autoirpm.update-all: %: %.cc 
	$(CXX) $(CFLAGS) $< $(LIBRPM) -o $@

test:
	cd test; ./do_alltests

tar: clean
	cd .. ; tar cf - urpmi | bzip2 -9 >$(TAR)

rpm: tar 
	cp -f ../$(TAR) $(RPM)/SOURCES
	cp -f $(LOG) $(RPM)/SOURCES
	cp -f $(NAME).spec $(RPM)/SPECS/
	-rpm -ba $(NAME).spec
	rm -f ../$(TAR)

po:
	$(MAKE) -C $@

clean:
	$(MAKE) -C po $@
	rm -f *~ autoirpm.update-all
