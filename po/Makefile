POFILES = $(shell ls *.po)
LOCALEDIR = $(PREFIX)/usr/share/locale

all: $(POFILES)

install: $(POFILES)
	for i in $(POFILES:%.po=%); do \
           install -d $(LOCALEDIR)/$$i/LC_MESSAGES ; \
           cp -f $$i.po $(LOCALEDIR)/$$i/LC_MESSAGES/urpmi.po ; \
        done

clean:
	rm -f messages empty.po $(POFILES:%=%t)

$(POFILES): urpmi.pot
	cp -f $@ $@t
	msgmerge $@t $< > $@
	rm $@t

urpmi.pot: ../urpmi
	xgettext -L C -F -n --keyword=_ -o $@ $<
