# Installation directories
localedir = $(PREFIX)/usr/share/locale

PGOAL = urpmi

# perl files to search translatable strings in
PL_FILES = ../_irpm ../urpm.pm ../urpme ../urpmi ../urpmi.addmedia \
	../urpmi.removemedia ../urpmi.update ../urpmq \
	../urpm/parallel_ka_run.pm  ../urpm/parallel_ssh.pm
# C-like files to search translatable strings in
CFILES = ./placeholder.h

PL_CFILES = $(PL_FILES:%=%_.c)
POFILES = $(shell ls *.po)
MOFILES = $(POFILES:%.po=%.mo)
LANGS = $(POFILES:%.po=%)

GOALS = $(PGOAL).pot  $(MOFILES)


all: $(GOALS)

%.mo: %.po
	msgfmt -o $@ $<

$(PL_CFILES): %_.c: %
	./fake_c.pl $< > $@

merge: $(PGOAL).pot
	@for n in $(POFILES); do \
		echo "Merging $$n"; \
		msgmerge "$$n" $< > "$$n"t; \
		mv -f "$$n"t "$$n"; \
	done

$(PGOAL).pot: $(PL_CFILES) $(CFILES)
	./create_placeholder
	xgettext --default-domain=$(PGOAL) -F -n \
	--add-comments='-PO' --add-comments=' Translator:'\
	--keyword=_ --keyword=__ --keyword=N_ --keyword=gettext \
	--language=C $(PL_CFILES) $(CFILES)
	mv -f $(PGOAL).po $(PGOAL).pot
	@rm -rf $(PL_CFILES)

install: all
	for l in $(LANGS); do \
		install -d $(localedir)/$$l/LC_MESSAGES; \
		install -m 644 $$l.mo $(localedir)/$$l/LC_MESSAGES/$(PGOAL).mo; \
	done

clean:
	@rm -rf *~ *.mo $(GOALS) $(PL_CFILES) 


