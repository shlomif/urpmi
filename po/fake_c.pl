#!/usr/bin/perl -lp

s|^(__?\()| $1|;		# add a blank at the beginning (?!)

s|_\(\[(.*),\s*(.*),\s*(.*)\]|ngettext($2,$3,$1)|; # special plural form handling

s,\Qs/#.*//,,;			# ugly special case

s,(^|[^\$])#([^+].*),"$1/*" . simpl($2) . "*/",e; 
                                # rewrite comments to C format except for:
                                # - ``#+ xxx'' comments which are kept
                                # - ``$#xxx'' which are not comments

s|//|/""/|g;			# ensure // or not understood as comments

s|$|\\n\\|;			# multi-line strings not handled in C

sub simpl {
    local $_ = $_[0];
    s,\*/,,g;
    $_;
}
