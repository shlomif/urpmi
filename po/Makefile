# Installation directories
localedir = $(PREFIX)/usr/share/locale

LANGS = $(shell ls *.po | xargs -i basename {} .po )
PGOAL = urpmi
GOALS = $(PGOAL).pot  $(foreach a, $(LANGS), $(a).mo)
POTFILES = $(shell sed -e "s+^+../+" "POTFILES.in" )


all: $(GOALS)

install: all
	for l in $(LANGS); do \
		install -d $(localedir)/$$l/LC_MESSAGES; \
		install -m 644 $$l.mo $(localedir)/$$l/LC_MESSAGES/$(PGOAL).mo; \
	done

clean:
	rm -f *~ *.[oas] *.mo $(GOALS) TAGS

%.h:
	@touch $@

%.mo: %.po
	msgfmt -o $@ $<

%.pot:	$(POTFILES)
	./create_placeholder $(POTFILES)
	xgettext --default-domain=`basename $@ .pot` --add-comments \
	        --keyword=__ --keyword=_ --keyword=N_ --keyword=gettext \
		placeholder.h && \
	mv `basename $@ .pot`.po $@

