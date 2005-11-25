# Installation directories
PREFIX ?= $(DESTDIR)
localedir = $(PREFIX)/usr/share/locale

PGOAL = urpmi

# perl files to search translatable strings in
PL_FILES = ../rpm-find-leaves ../urpm.pm ../urpme ../urpmf \
	../urpmi ../urpmi.addmedia ../gurpmi ../gurpmi2 ../gurpmi.pm \
	../urpmi.removemedia ../urpmi.update ../urpmq \
	../urpm/parallel_ka_run.pm ../urpm/parallel_ssh.pm \
	../urpm/msg.pm ../urpm/args.pm ../rurpmi
# C-like files to search translatable strings in
CFILES = ./placeholder.h

POFILES = $(shell ls *.po)
MOFILES = $(POFILES:%.po=%.mo)
LANGS = $(POFILES:%.po=%)

GOALS = $(PGOAL).pot $(MOFILES)

all: $(GOALS)

%.mo: %.po
	msgfmt -o $@ $<

placeholder.h:
	./create_placeholder

merge: $(PGOAL).pot
	@for n in $(POFILES); do \
	    echo "Merging $$n"; \
	    msgmerge "$$n" $< > "$$n"t; \
	    mv -f "$$n"t "$$n"; \
	done

$(PGOAL).pot: $(CFILES)
	xgettext -F -n --add-comments \
	  --keyword=_ --keyword=__ --keyword=N_ --keyword=N \
	  --keyword=gettext \
	  --language=C -o placeholder.pot $(CFILES)
	xgettext -F -n --add-comments \
	  --keyword=N_ --keyword=N \
	  --language=Perl -o $(PGOAL)_tmp.pot $(PL_FILES)
	[ ! -e $(PGOAL)_tmp.pot ] || msgcat --use-first placeholder.pot $(PGOAL)_tmp.pot > $@
	perl -pi -es/perl-format/c-format/ $@
	rm -f placeholder.pot $(PGOAL)_tmp.pot

install: all
	for l in $(LANGS); do \
	    install -d $(localedir)/$$l/LC_MESSAGES; \
	    install -m 644 $$l.mo $(localedir)/$$l/LC_MESSAGES/$(PGOAL).mo; \
	done

clean:
	@rm -rf *~ *.mo $(GOALS) placeholder.pot $(PGOAL)_tmp.pot
