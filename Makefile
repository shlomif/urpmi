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

.PHONY: install clean rpm test bigtest perltest changelog ChangeLog

install:
	$(MAKE) -C po $@
	install -d $(BINDIR) $(SBINDIR) $(URPMIDIR) $(URPMIDIR2) $(MANDIR)/man5 $(MANDIR)/man8
	install urpmq $(BINDIR)
	install rpm-find-leaves urpmf $(BINDIR)
#	install -m 644 autoirpm.deny $(URPMIDIR2)
	install -m 644 skip.list $(URPMIDIR2)
	install -m 644 man/C/urpm*.5 $(MANDIR)/man5
	install -m 644 man/C/proxy*.5 $(MANDIR)/man5
	install -m 644 man/C/urpm*.8 $(MANDIR)/man8
	install urpmi urpme urpmi.addmedia urpmi.update urpmi.removemedia rurpmi $(SBINDIR)
#	install -s autoirpm.update-all $(SBINDIR)
#	ln -sf urpmi.addmedia $(SBINDIR)/urpmi.removemedia
#	ln -sf urpmi.addmedia $(SBINDIR)/urpmi.update
	install gurpmi $(BINDIR)
	install gurpmi2 $(SBINDIR)
	ln -s -f ../../usr/bin/consolehelper $(BINDIR)/gurpmi2
	for i in man/??* ; \
		do install -d $(MANDIR)/`basename $$i`/man8 ; \
		install -m 644 $$i/urpm*.8 $(MANDIR)/`basename $$i`/man8 ; \
	done	

autoirpm.update-all: %: %.cc 
	$(CXX) $(CFLAGS) $< $(LIBRPM) -o $@

test: bigtest perltest

perltest:
	prove t/*.t

bigtest:
	cd test; ./do_alltests

tar: clean
	cd .. ; tar cf - urpmi | bzip2 -9 >$(TAR)

rpm: tar 
	cp -f ../$(TAR) $(RPM)/SOURCES
	cp -f $(NAME).spec $(RPM)/SPECS/
	-rpm -ba --clean $(NAME).spec
	rm -f ../$(TAR)

po:
	$(MAKE) -C $@

clean:
	$(MAKE) -C po $@
	rm -f *~ autoirpm.update-all

changelog:
	cvs2cl -W 400 -I ChangeLog --accum -U ../../soft/common/username
	rm -f *.bak

log:	changelog

ChangeLog: changelog
