# Installation directories
localedir = $(prefix)/usr/share/locale

LANGS = $(shell ls *.po | xargs -i basename {} .po )
PGOAL = urpmi
GOALS = $(PGOAL).pot  $(foreach a, $(LANGS), $(a).mo)

# $(foreach a, $(LANGS), $($(a).mo))

all: $(GOALS)

install: all
	for l in $(LANGS); do \
		install -d $(localedir)/$$l/LC_MESSAGES; \
		install -m 644 $$l.mo $(localedir)/$$l/LC_MESSAGES/$(PGOAL).mo; \
	done

clean:
	rm -f *~ *.[oas] *.mo $(GOALS) TAGS

%.mo: %.po
	msgfmt -o $@ $<

%.pot:	POTFILES.in
	./create_placeholder 
	xgettext --default-domain=`basename $@ .pot` --directory=.. \
		--add-comments --keyword=__ --keyword=_ --keyword=N_ \
		--keyword=I_ --keyword=i18n
		--files-from=./POTFILES.in && \
	mv `basename $@ .pot`.po $@

