# Installation directories
localedir = $(PREFIX)/usr/share/locale

PGOAL = urpmi

# perl files to search translatable strings in
PL_FILES = ../_irpm ../rpm-find-leaves ../urpm.pm ../urpme ../urpmf \
	../urpmi ../urpmi.addmedia ../gurpmi \
	../urpmi.removemedia ../urpmi.update ../urpmq \
	../urpm/parallel_ka_run.pm  ../urpm/parallel_ssh.pm \
	../urpm/msg.pm ../urpm/args.pm
# C-like files to search translatable strings in
CFILES = ./placeholder.h

POFILES = $(shell ls *.po)
MOFILES = $(POFILES:%.po=%.mo)
LANGS = $(POFILES:%.po=%)

GOALS = $(PGOAL).pot  $(MOFILES)


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
	perl_checker -q --generate-pot $(PGOAL)_tmp.pot $(PL_FILES) || rm -f $(PGOAL)_tmp.pot
	[ ! -e $(PGOAL)_tmp.pot ] || msgcat --use-first placeholder.pot $(PGOAL)_tmp.pot > $@
	rm -f placeholder.pot $(PGOAL)_tmp.pot

install: all
	for l in $(LANGS); do \
		install -d $(localedir)/$$l/LC_MESSAGES; \
		install -m 644 $$l.mo $(localedir)/$$l/LC_MESSAGES/$(PGOAL).mo; \
	done

clean:
	@rm -rf *~ *.mo $(GOALS) placeholder.pot $(PGOAL)_tmp.pot 


