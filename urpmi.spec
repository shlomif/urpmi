%define group System/Configuration/Packaging

Name: urpmi
Version: 1.5
Release: 2mdk
License: GPL
Source0: %{name}.tar.bz2
Summary: User mode rpm install
Requires: /usr/bin/suidperl, eject, wget
PreReq: perl-gettext, rpmtools >= 2.3
BuildRoot: %{_tmppath}/%{name}-buildroot

Group: %{group}
%description
urpmi enable non-superuser install of rpms. In fact, it only authorizes
well-known rpms to be installed.

You can compare rpm vs. urpmi  with  insmod vs. modprobe

%package -n gurpmi
Version: 0.9
Summary: User mode rpm GUI install
Requires: urpmi grpmi gchooser gmessage
Group: %{group}
%description -n gurpmi
gurpmi enable non-superuser install of rpms. In fact, it only authorizes
well-known rpms to be installed.

You can compare rpm vs. urpmi  with  insmod vs. modprobe

%package -n autoirpm
Version: 0.7
Summary: Auto install of rpm on demand
Requires: sh-utils urpmi gurpmi xtest gmessage gurpmi
Group: %{group}

%description -n autoirpm
Auto install of rpm on demand


%prep
%setup -q -n %{name}

%install
rm -rf $RPM_BUILD_ROOT
make PREFIX=$RPM_BUILD_ROOT MANDIR=$RPM_BUILD_ROOT%{_mandir} install
install -d $RPM_BUILD_ROOT/var/lib/urpmi/autoirpm.scripts
for dir in partial headers rpms
do
  install -d $RPM_BUILD_ROOT/var/cache/urpmi/$dir
done
install -m 644 autoirpm.deny $RPM_BUILD_ROOT/etc/urpmi
mkdir -p $RPM_BUILD_ROOT%{perl_sitearch}
install -m 644 urpm.pm $RPM_BUILD_ROOT%{perl_sitearch}

find $RPM_BUILD_ROOT%{_datadir}/locale -name %{name}.po | \
    perl -pe 'm|locale/([^/_]*)(.*)|; $_ = "%%lang($1) %{_datadir}/locale/$1$2\n"' > %{name}.lang

cd $RPM_BUILD_ROOT%{_bindir} ; mv -f rpm-find-leaves urpmi_rpm-find-leaves


%find_lang %{name}

%clean
rm -rf $RPM_BUILD_ROOT
rm -rf $RPM_BUILD_DIR/$RPM_PACKAGE_NAME

%pre
groupadd -r -f urpmi

%preun
if [ "$1" = "0" ]; then
  rm -rf /var/lib/urpmi/*
fi
exit 0

%post
rm -f /var/lib/urpmi/depslist
[ -z "$DURING_INSTALL" ] && %{_sbindir}/urpmi.update -a

%preun -n autoirpm
autoirpm.uninstall

%files -f %{name}.lang
%defattr(-,root,root)
%attr(0755, root, urpmi) %dir /etc/urpmi
%attr(0755, root, urpmi) %dir /var/lib/urpmi
%attr(0755, root, urpmi) %dir /var/cache/urpmi
%attr(0755, root, urpmi) %dir /var/cache/urpmi/partial
%attr(0755, root, urpmi) %dir /var/cache/urpmi/headers
%attr(0755, root, urpmi) %dir /var/cache/urpmi/rpms
%attr(4750, root, urpmi) %{_bindir}/urpmi
%{_bindir}/urpmi_rpm-find-leaves
%{_bindir}/urpmf
%{_bindir}/urpmq
%{_sbindir}/urpme
%{_sbindir}/urpmi.*
%{_mandir}/*/urpm*
%{perl_sitearch}/urpm.pm

%files -n gurpmi
%defattr(-,root,root)
/usr/X11R6/bin/gurpmi

%files -n autoirpm
%defattr(-,root,root)
%dir /var/lib/urpmi/autoirpm.scripts
%config(noreplace) /etc/urpmi/autoirpm.deny
%{_sbindir}/autoirpm.*
%{_mandir}/*/autoirpm*
%{_bindir}/_irpm
%doc README-autoirpm-icons autoirpm.README


%changelog
* Wed Feb 14 2001 François Pons <fpons@mandrakesoft.com> 1.5-2mdk
- removable medium are not automatically updated now.
- remove need of number removable device when adding a new medium.

* Wed Feb 14 2001 François Pons <fpons@mandrakesoft.com> 1.5-1mdk
- added --auto-select flag for urpmi and urpmq.
- added --headers flag to urpmq.
- changed help screen for both urpmi and urpmq.

* Mon Feb 05 2001 François Pons <fpons@mandrakesoft.com> 1.4-7mdk
- fixed wrong probing of medium list file.

* Mon Feb  5 2001 François Pons <fpons@mandrakesoft.com> 1.4-6mdk
- fixed missing mounting on non removable device like nfs.
- flush STDERR and STDOUT before exiting.

* Tue Jan 30 2001 François Pons <fpons@mandrakesoft.com> 1.4-5mdk
- added medium change code.
- fixed urpmi with local file.
- changed default option to verbose when invoking rpm.


* Thu Jan 25 2001 François Pons <fpons@mandrakesoft.com> 1.4-4mdk
- added code to search for source rpms file to install.
- modified manipulation of ignore flag, keep media name unique.
- added missing cache directory in spec file.
- lot of fixes on urpm core library.

* Thu Jan 25 2001 François Pons <fpons@mandrakesoft.com> 1.4-3mdk
- need rpmtools-2.1-9mdk or above for hdlist building extension.
- introduced cache directory for medium and rpms manipulation.

* Wed Jan 17 2001 François Pons <fpons@mandrakesoft.com> 1.4-2mdk
- removed PreReq on genbasefiles, now PreReq rpmtools-2.1-8mdk or above.
- fixed glitches in urpm.pm module about old format of urpmi.cfg.

* Tue Jan 16 2001 François Pons <fpons@mandrakesoft.com> 1.4-1mdk
- extract urpmi/urpmq common code and newer code for medium
  management in perl module urpm.
- rewrite tools to use the module.

* Mon Nov 27 2000 François Pons <fpons@mandrakesoft.com> 1.3-12mdk
- fixed urpmi.addmedia if already added media are no more accessible.

* Thu Nov 16 2000 François Pons <fpons@mandrakesoft.com> 1.3-11mdk
- fixed compilation problems.

* Mon Sep 25 2000 François Pons <fpons@mandrakesoft.com> 1.3-10mdk
- updated urpme to depslist.ordered.

* Wed Sep 20 2000 Guillaume Cottenceau <gc@mandrakesoft.com> 1.3-9mdk
- in --auto under X, does not display anymore the sucking interactive dialog
  "everything already installed"

* Wed Sep 20 2000 Guillaume Cottenceau <gc@mandrakesoft.com> 1.3-8mdk
- added option --best-output that selects X if available

* Wed Sep 13 2000 François Pons <fpons@mandrakesoft.com> 1.3-7mdk
- trusting root only readable file list.*, fixes gurpmi with
  mutlitple media examination.
- removed setuid root on urpmq.

* Tue Sep 05 2000 François Pons <fpons@mandrakesoft.com> 1.3-6mdk
- split query mode of urpmi into new tools urpmq.
- fixed -v option of urpmi.
- updated man pages of various tools.

* Sun Sep 03 2000 François Pons <fpons@mandrakesoft.com> 1.3-5mdk
- fixed incorporation of media with already defined packages, choose the
  relocated one by rpmtools library.

* Fri Sep 01 2000 François Pons <fpons@mandrakesoft.com> 1.3-4mdk
- fixed --auto usage (thanks to Garbage Collector).
- fixed urpmi.addmedia with glob on rpm files only.

* Thu Aug 31 2000 François Pons <fpons@mandrakesoft.com> 1.3-3mdk
- Oops, fixed typo in post.

* Tue Aug 31 2000 François Pons <fpons@mandrakesoft.com> 1.3-2mdk
- added code to proper upgrade of urpmi 1.2.
- added small correction in urpmi for basesystem selection.
- fixed help invocation (thanks to Bryan Paxton).
- modified urpmf not to use rpmtools-compat.

* Mon Aug 28 2000 François Pons <fpons@mandrakesoft.com> 1.3-1mdk
- 1.3 of urpmi.
- use rpmtools perl interface to access hdlist and build requires.

* Sun Aug  6 2000 Pixel <pixel@mandrakesoft.com> 1.2-4mdk
- use %%lang for i18n'd files
- clean /var/lib/urpmi on removal
- urpmi local_file only if local_file ends with .rpm

* Wed Jul 19 2000 Pixel <pixel@mandrakesoft.com> 1.2-3mdk
- change versions of autoirpm and gurpmi
- macroization, BM

* Thu Jun 29 2000 Pixel <pixel@mandrakesoft.com> 1.2-1mdk
- nice fixes from diablero (mainly better generation of list.*)

* Tue Jun 13 2000 Pixel <pixel@mandrakesoft.com> 1.1-7mdk
- add require wget (needed for ftp hdlist's)

* Thu May  4 2000 Pixel <pixel@mandrakesoft.com> 1.1-6mdk
- urpmi: unset IFS

* Tue Apr  4 2000 Pixel <pixel@mandrakesoft.com> 1.1-5mdk
- urpmi: add option --force to ignore errors

* Sun Mar 26 2000 Pixel <pixel@mandrakesoft.com> 1.1-4mdk
- autoirpm.update: adapted to new hdlist format

* Sun Mar 26 2000 Pixel <pixel@mandrakesoft.com> 1.1-3mdk
- urpmi can handle package files given on command line. It finds out the
dependencies if possible.
- added rpme (try it, you'll like it!)
- don't try nodeps if file is missing
- new group
- adapted urpmi.addmedia to new hdlist's / multi-cd
- adapted autoirpm.update-all to new rpmlib

* Thu Mar 16 2000 Pixel <pixel@mandrakesoft.com> 1.1-2mdk
- increase version number of gurpmi and autoirpm

* Tue Mar  7 2000 Pixel <pixel@mandrakesoft.com> 1.1-1mdk
- new version, compatible with new DrakX and new rpmtools
- add man page for rpmf

* Mon Feb 28 2000 Pixel <pixel@mandrakesoft.com> 1.0-2mdk
- unset $BASH_ENV

* Sat Feb 12 2000 Pixel <pixel@mandrakesoft.com> 1.0-1mdk
- 1.0
- small urpmi man page change

* Thu Feb 10 2000 Pixel <pixel@mandrakesoft.com> 0.9-40mdk
- unset $ENV to please -U

* Wed Feb  9 2000 Pixel <pixel@mandrakesoft.com> 0.9-39mdk
- now really handle multiple args
- new option ``-a'' to install all the proposed packages
- add ability to --nodeps and --force in case of install errors

* Mon Jan 10 2000 Pixel <pixel@mandrakesoft.com>
- bug fix from Brian J. Murrell

* Fri Jan  7 2000 Pixel <pixel@mandrakesoft.com>
- urpmi: tty question now defaults to yes and acts that way!
- add an example to urpmi.addmedia.8

* Thu Jan  6 2000 Pixel <pixel@mandrakesoft.com>
- urpmi: tty question now defaults to yes (y/N -> N/y)

* Tue Jan  4 2000 Chmouel Boudjnah <chmouel@mandrakesoft.com> 0.9-34mdk
- rpmf: use egrep.

* Tue Jan  4 2000 Pixel <pixel@mandrakesoft.com>
- urpmi.addmedia: replaced hdlist2files by hdlist2names
- rpmf: created 

* Mon Dec 27 1999 Pixel <pixel@mandrakesoft.com>
- fixed a bug in urpmi.addmedia

* Fri Dec 24 1999 Pixel <pixel@mandrakesoft.com>
- more i18n

* Wed Dec 22 1999 Pixel <pixel@mandrakesoft.com>
- added urpmi_rpm-find-leaves

* Mon Dec 20 1999 Pixel <pixel@mandrakesoft.com>
- bug fix in autoirpm.update

* Sun Dec 19 1999 Pixel <pixel@mandrakesoft.com>
- bug fix for autoirpm (bad directory)
- enhancement to urpmi (in place gzip'ing)
- small cute enhancements

* Sat Dec 18 1999 Pixel <pixel@mandrakesoft.com>
- a lot of i18n added (thx2pablo)

* Fri Dec 17 1999 Pixel <pixel@mandrakesoft.com>
- changed a message

* Thu Dec 16 1999 Pixel <pixel@mandrakesoft.com>
- added -follow to the find (thanx2(ti){2})

* Wed Dec 15 1999 Pixel <pixel@mandrakesoft.com>
- fixed a bug in dependencies

* Sat Dec 11 1999 Pixel <pixel@mandrakesoft.com>
- i18n using po-like style

* Wed Dec  8 1999 Pixel <pixel@linux-mandrake.com>
- fixed a bug (gmessage called with no double quotes and i18n)

* Thu Dec  2 1999 Pixel <pixel@linux-mandrake.com>
- better error output (both in /var/log/urpmi.* and stdout/stderr)

* Fri Nov 26 1999 Pixel <pixel@linux-mandrake.com>
- some bug fixes

* Tue Nov 23 1999 Pixel <pixel@linux-mandrake.com>
- include new man pages and doc from camille :)

* Mon Nov 22 1999 Pixel <pixel@mandrakesoft.com>
- s|sbin|bin| in requires (again) (wow already monday!)

* Sun Nov 21 1999 Pixel <pixel@mandrakesoft.com>
- autoirpm: added require gurpmi

* Sat Nov 20 1999 Pixel <pixel@mandrakesoft.com>
- urpmi.addmedia modified

* Wed Nov 17 1999 Pixel <pixel@mandrakesoft.com>
- corrected error in urpmi script
- replaced dependency perl by /usr/bin/suidperl

* Mon Nov 15 1999 Pixel <pixel@linux-mandrake.com>
- changed the handling of urpmi, added urpmi.addmedia...
