%define group System/Configuration/Packaging

Name: urpmi
Version: 4.1
Release: 11mdk
License: GPL
Source0: %{name}.tar.bz2
Source1: %{name}.logrotate
Summary: User mode rpm install
URL: http://cvs.mandrakesoft.com/cgi-bin/cvsweb.cgi/soft/urpmi
Requires: eject webfetch perl-DateManip >= 5.40
PreReq: perl-Locale-gettext rpmtools >= 4.3-6mdk perl-URPM >= 0.80
BuildRequires: bzip2-devel gettext rpm-devel >= 4.0.3
BuildRoot: %{_tmppath}/%{name}-buildroot
BuildArch: noarch

Group: %{group}
%description
urpmi takes care of dependencies between rpms, using a pool (or pools) of rpms.

You can compare rpm vs. urpmi  with  insmod vs. modprobe

%package -n gurpmi
Summary: User mode rpm GUI install
Requires: urpmi grpmi gchooser gmessage usermode menu
Group: %{group}
%description -n gurpmi
gurpmi is a graphical front-end to urpmi

#%package -n autoirpm
#Summary: Auto install of rpm on demand
#Requires: sh-utils urpmi gurpmi xtest gmessage gurpmi perl
#Group: %{group}
#
#%description -n autoirpm
#Auto install of rpm on demand

%package -n urpmi-parallel-ka-run
Summary: Parallel extensions to urpmi using ka-run
Requires: urpmi >= 4.1-8mdk ka-run >= 2.0-15mdk
Group: %{group}
%description -n urpmi-parallel-ka-run
urpmi-parallel-ka-run is an extensions module to urpmi for handling
distributed installation using ka-run tools.

%package -n urpmi-parallel-ssh
Summary: Parallel extensions to urpmi using ssh and scp
Requires: urpmi >= 4.1-8mdk openssh-clients
Group: %{group}
%description -n urpmi-parallel-ssh
urpmi-parallel-ssh is an extensions module to urpmi for handling
distributed installation using ssh and scp tools.

%prep
%setup -q -n %{name}

%install
rm -rf $RPM_BUILD_ROOT
make PREFIX=$RPM_BUILD_ROOT MANDIR=$RPM_BUILD_ROOT%{_mandir} install
#install -d $RPM_BUILD_ROOT/var/lib/urpmi/autoirpm.scripts
for dir in partial headers rpms
do
  install -d $RPM_BUILD_ROOT/var/cache/urpmi/$dir
done
#install -m 644 autoirpm.deny $RPM_BUILD_ROOT/etc/urpmi
cat <<EOF >$RPM_BUILD_ROOT/etc/urpmi/inst.list
# Here you can specify packages that need to be installed instead
# of being upgraded (typically kernel packages).
kernel
kernel-smp
kernel-secure
kernel-enterprise
kernel-linus2.2
kernel-linus2.4
kernel22
kernel22-secure
kernel22-smp
hackkernel
EOF

mkdir -p $RPM_BUILD_ROOT%{perl_vendorlib}
install -m 644 urpm.pm $RPM_BUILD_ROOT%{perl_vendorlib}/urpm.pm
mkdir -p $RPM_BUILD_ROOT%{perl_vendorlib}/urpm
install -m 644 urpm/parallel_ka_run.pm $RPM_BUILD_ROOT%{perl_vendorlib}/urpm/parallel_ka_run.pm
install -m 644 urpm/parallel_ssh.pm $RPM_BUILD_ROOT%{perl_vendorlib}/urpm/parallel_ssh.pm
mkdir -p $RPM_BUILD_ROOT%{_mandir}/man3
pod2man urpm.pm >$RPM_BUILD_ROOT%{_mandir}/man3/urpm.3

#find $RPM_BUILD_ROOT%{_datadir}/locale -name %{name}.mo | \
#    perl -pe 'm|locale/([^/_]*)(.*)|; $_ = "%%lang($1) %{_datadir}/locale/$1$2\n"' > %{name}.lang

mv -f $RPM_BUILD_ROOT%{_bindir}/rpm-find-leaves $RPM_BUILD_ROOT%{_bindir}/urpmi_rpm-find-leaves

mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d/
install -m 644 %{SOURCE1} $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d/urpmi

mkdir -p $RPM_BUILD_ROOT%{_menudir}
cat << EOF > $RPM_BUILD_ROOT%{_menudir}/gurpmi
?package(gurpmi): command="%{_bindir}/gurpmi" needs="gnome" section=".hidden" \
section=".hidden" \
title="Software installer" longtitle="Graphical front end to install RPM files" \
mimetypes="application/x-rpm" \
multiple_files="true"
?package(gurpmi): command="%{_bindir}/gurpmi" needs="kde" section=".hidden" \
section=".hidden" InitialPreference="9" \
title="Software installer" longtitle="Graphical front end to install RPM files" \
mimetypes="application/x-rpm" \
multiple_files="true"
EOF


%find_lang %{name}

%clean
rm -rf $RPM_BUILD_ROOT
rm -rf $RPM_BUILD_DIR/$RPM_PACKAGE_NAME

%preun
if [ "$1" = "0" ]; then
  cd /var/lib/urpmi
  rm -f compss provides depslist* descriptions.* *.cache hdlist.* synthesis.hdlist.* list.*
  cd /var/cache/urpmi
  rm -rf partial/* headers/* rpms/*
fi
exit 0

%post
cd /var/lib/urpmi
rm -f compss provides depslist*
misconfigured=0
for hdlist in hdlist.*; do
  if [ -s "$hdlist" -a ! -s "synthesis.$hdlist" ]; then
     misconfigured=1
  fi
done
if [ -z "$DURING_INSTALL" -a "$misconfigured" -ge 1 ]; then
  rm -f synthesis.hdlist.* && %{_sbindir}/urpmi.update -a
fi

#%preun -n autoirpm
#[ -x %{_sbindir}/autoirpm.uninstall ] && %{_sbindir}/autoirpm.uninstall

%post -n gurpmi
%{update_menus}

%postun -n gurpmi
%{clean_menus}

%files -f %{name}.lang
%defattr(-,root,root)
%dir /etc/urpmi
%dir /var/lib/urpmi
%dir /var/cache/urpmi
%dir /var/cache/urpmi/partial
%dir /var/cache/urpmi/headers
%dir /var/cache/urpmi/rpms
%config(noreplace) /etc/urpmi/skip.list
%config(noreplace) /etc/urpmi/inst.list
%config(noreplace) %{_sysconfdir}/logrotate.d/%{name}
%{_bindir}/urpmi_rpm-find-leaves
%{_bindir}/urpmf
%{_bindir}/urpmq
%{_sbindir}/urpmi
%{_sbindir}/urpme
%{_sbindir}/urpmi.*
%{_mandir}/man?/urpm*
# find_lang isn't able to find man pages yet...
%lang(cs) %{_mandir}/cs/man?/urpm* 
%lang(eu) %{_mandir}/eu/man?/urpm* 
%lang(fr) %{_mandir}/fr/man?/urpm* 
%lang(ru) %{_mandir}/ru/man?/urpm* 
%{perl_vendorlib}/urpm.pm

%files -n gurpmi
%defattr(-,root,root)
%{_sbindir}/gurpmi
%{_bindir}/gurpmi
%{_menudir}/gurpmi


#%files -n autoirpm
#%defattr(-,root,root)
#%dir /var/lib/urpmi/autoirpm.scripts
#%config(noreplace) /etc/urpmi/autoirpm.deny
#%{_sbindir}/autoirpm.*
#%{_mandir}/man?/autoirpm*
## find_lang isn't able to find man pages yet...
#%lang(cs) %{_mandir}/cs/man?/autoirpm*
#%lang(eu) %{_mandir}/eu/man?/autoirpm*
#%lang(fr) %{_mandir}/fr/man?/autoirpm*
#%lang(ru) %{_mandir}/ru/man?/autoirpm*
#%{_bindir}/_irpm
#%doc README-autoirpm-icons autoirpm.README

%files -n urpmi-parallel-ka-run
%defattr(-,root,root)
%doc urpm/README.ka-run
%{perl_vendorlib}/urpm/parallel_ka_run.pm

%files -n urpmi-parallel-ssh
%defattr(-,root,root)
%doc urpm/README.ssh
%{perl_vendorlib}/urpm/parallel_ssh.pm


%changelog
* Tue Dec 10 2002 François Pons <fpons@mandrakesoft.com> 4.1-11mdk
- fixed source installation in / when installing dependencies.
- added --install-src to avoid probing on root/user mode.
- fixed no log available when user mode.
- changed obsoleted -c of urpmq to complete output with package
  to removes (needed for parallel distributed urpme).
- allow distribution of local files.
- fixed small typos in urpme.

* Fri Dec  6 2002 François Pons <fpons@mandrakesoft.com> 4.1-10mdk
- fixed indexation when using --distrib-XXX for urpmi.addmedia.
- fixed wget output to be far more quietly.

* Fri Dec  6 2002 François Pons <fpons@mandrakesoft.com> 4.1-9mdk
- improved urpmf from sh to perl, now a lot of options and
  support of synthesis only media.
- make medium name mandatory when adding a source with
  --distrib-XXX using urpmi.addmedia.
- fix parallel installation when one node is already up-to-date.
- improved callback usage of urpm::configure to use newer
  perl-URPM interface (much faster and smart with memory, but
  unstable).

* Tue Dec  3 2002 François Pons <fpons@mandrakesoft.com> 4.1-8mdk
- added --excludepath option (fix bug 577).
- fixed missing options given to parallel plugins.
- fixed missing files not given to user.

* Mon Dec  2 2002 François Pons <fpons@mandrakesoft.com> 4.1-7mdk
- fixed rsync:// protocol, now it really works, tested.

* Mon Dec  2 2002 François Pons <fpons@mandrakesoft.com> 4.1-6mdk
- fixed mutliple second or more medium being ignored when not
  using a list file.
- fixed problem of package not found when not using list file.
- fixed urpmi --auto.

* Fri Nov 29 2002 François Pons <fpons@mandrakesoft.com> 4.1-5mdk
- changed urpmi.addmedia behaviour to use /etc/urpmi/mirror.config
  and allow it to parse urpmi.setup mirror configuration as
  well as Mandrake (old) mirror configuration.
- allow blank url to be given to get all mirror for a given version
  and architecture.

* Fri Nov 29 2002 François Pons <fpons@mandrakesoft.com> 4.1-4mdk
- allow urpmi <url> to work with rpm filename with all supported
  protocols (ftp, http, ssh, rsync).
- fixed rsync:// protocol not to use rsync with -e along with
  an rsync server.
- fixed missing list creation update.

* Thu Nov 28 2002 François Pons <fpons@mandrakesoft.com> 4.1-3mdk
- added mirrors management for urpmi.addmedia, so added
  --distrib-XXX, --from, --version, --arch options. <url>
  is now just a regex for choosing a mirror, and <name>
  will have an numeric index appended to it.
  anyway for more info, look in the code or guess with
  --help ;-) too late here in Paris ...
- urpmi.addmedia now delete failing media to create.
- added --update option to urpmi.update, guess for what ?

* Thu Nov 28 2002 François Pons <fpons@mandrakesoft.com> 4.1-2mdk
- allow creating medium without list file.
- better handling of url without password to be displayed
  in urpmi.cfg.
- fixed remaining list file in partial cache causing bad list file
  generation.

* Wed Nov 27 2002 François Pons <fpons@mandrakesoft.com> 4.1-1mdk
- fixed checking md5 of rpm files in cache.
- allow rpm files to be downloaded from alternate site.
- allow medium to not use a list file.

* Wed Nov 13 2002 François Pons <fpons@mandrakesoft.com> 4.0-25mdk
- fixed --noclean not really completely noclean.
- avoid possible lost of with_hdlist parameter on some case
  when updating a medium.

* Thu Nov  7 2002 François Pons <fpons@mandrakesoft.com> 4.0-24mdk
- fixed still present debug output of urpmq -R.
- fixed bad use of cached list file for file or nfs media.

* Tue Oct 29 2002 François Pons <fpons@mandrakesoft.com> 4.0-23mdk
- added MD5SUM file support for downloading hdlist/synthesis.
- added -R option to urpmq to search what may provide packages.

* Thu Oct 24 2002 François Pons <fpons@mandrakesoft.com> 4.0-22mdk
- fixed online help of tools to be more consistent.
- added some times missing --help options.
- fixed bad version displayed by urpmq.
- added --list-aliases to list parallel aliases.
- fixed bad rpm in cache by checking only MD5 signature.

* Wed Oct 16 2002 François Pons <fpons@mandrakesoft.com> 4.0-21mdk
- fixed bad copy of files when a relative symlink is used.
- added minimal README documentation files for distributed modules.
- fixed urpmi -P with package name already used by provides of
  other package.

* Tue Sep 17 2002 François Pons <fpons@mandrakesoft.com> 4.0-20mdk
- gc: fixed curl proxy management.

* Mon Sep 16 2002 François Pons <fpons@mandrakesoft.com> 4.0-19mdk
- fixed possible problem with http proxy for wget.
- umount removable device automatically mounted.

* Fri Sep 13 2002 François Pons <fpons@mandrakesoft.com> 4.0-18mdk
- removed apache2-conf from skip.list as it doesn't work
  when trying to install apache2.

* Thu Sep 12 2002 François Pons <fpons@mandrakesoft.com> 4.0-17mdk
- fixed possible no clean of distributed module.
- added apache2-conf to skip.list by default.
- fixed gurpmi usability.

* Wed Sep 11 2002 François Pons <fpons@mandrakesoft.com> 4.0-16mdk
- improved ka-run distributed module to copy all files with one
  invocation (newly supported in ka-run-2.0-15mdk).
- daouda: InitialPreference for gurpmi (clicking on a rpm under
          konqueror should launch gurpmi instead of kpackage).

* Fri Sep  6 2002 François Pons <fpons@mandrakesoft.com> 4.0-15mdk
- fixed previous fix not correctly fixed.

* Fri Sep  6 2002 François Pons <fpons@mandrakesoft.com> 4.0-14mdk
- fixed ka-run distributed module.

* Thu Sep  5 2002 François Pons <fpons@mandrakesoft.com> 4.0-13mdk
- simplified --proxy usage (http:// leading now optional).
- fixed --proxy and --proxy-user or urpmq.

* Thu Sep  5 2002 François Pons <fpons@mandrakesoft.com> 4.0-12mdk
- fixed bad englist message.
- updated translation.

* Fri Aug 30 2002 François Pons <fpons@mandrakesoft.com> 4.0-11mdk
- fixed no post-clean when testing or if errors occured.
- (fcrozat) fixed missing %%post and %%postun for gurpmi, fixed
  bad consolehelper require.

* Fri Aug 30 2002 François Pons <fpons@mandrakesoft.com> 4.0-10mdk
- fixed cache management (there could exist some files left in cache
  which were never deleted).
- added default cache management to post-clean (remove files of
  package correctly installed), it is still possible to keep old
  behaviour with "--pre-clean --no-post-clean".
- added --clean options to urpmi to clean cache completely.
- improved urpme to no more use rpm executable.
- (fcrozat) Move gurpmi to /usr/sbin and add consolehelper support for it 
  and register it to handle application/x-rpm mimetype.

* Thu Aug 29 2002 François Pons <fpons@mandrakesoft.com> 4.0-9mdk
- added --list-nodes to list nodes used when in parallel mode.
- moved some initialisation for parallel mode to allow user
  execution of --list-nodes.
- updated man pages with newer options.

* Thu Aug 29 2002 François Pons <fpons@mandrakesoft.com> 4.0-8mdk
- added --parallel option to urpmq.
- allowed test upgrade in parallel mode.
- improved first choices in parallel mode a little.

* Wed Aug 28 2002 François Pons <fpons@mandrakesoft.com> 4.0-7mdk
- added --list-media to urpmq.
- fixed old package not upgraded.

* Tue Aug 27 2002 François Pons <fpons@mandrakesoft.com> 4.0-6mdk
- fixed skip.list new format.

* Tue Aug 27 2002 François Pons <fpons@mandrakesoft.com> 4.0-5mdk
- fixed urpmq --auto-select disabling its selection.
- open read-only rpmdb when testing installation (--test).
- added reverse media parameter from parallel configuration.
- improved error management of parallel extension module.

* Mon Aug 26 2002 François Pons <fpons@mandrakesoft.com> 4.0-4mdk
- english typo fixed.
- improved skip.list contents to provides using sense and regexp
  on package fullname.
- added --test options to urpmi to test installation.
- made --verify-rpm the default (use --no-verify-rpm to avoid).
- fixed command line not seen in log.
- improved parallel module to check installation on all nodes before
  doing it effectively.

* Fri Aug 23 2002 Warly <warly@mandrakesoft.com> 4.0-3mdk
- fix urpme '/' pb

* Fri Aug 23 2002 François Pons <fpons@mandrakesoft.com> 4.0-2mdk
- added ssh parallel module extension.
- fixed check of capabilities of distant urpmi.
- fixed wrong installation of extension modules.

* Fri Aug 23 2002 François Pons <fpons@mandrakesoft.com> 4.0-1mdk
- added --parallel options for distributed urpmi.
- added urpmi module extensions support (only --parallel).
- added --synthesis options for urpmq/urpmi to use a specific
  environment.
- use cache files even if no medium have been defined (for use
  with --synthesis).

* Tue Aug 13 2002 François Pons <fpons@mandrakesoft.com> 3.9-8mdk
- fixed development log still done for progression status, now
  removed.
- ignore noauto: hdlists flags.

* Mon Aug 12 2002 François Pons <fpons@mandrakesoft.com> 3.9-7mdk
- fixed --auto not taken into account for removing or unselecting
  packages in urpmi.
- fixed modified flag ignored in urpmi.cfg (may cause side effects
  as remove media not asked next time urpmi.removemedia is called).
- added --verify-rpm to urpmi in order to check rpm signature.

* Tue Aug  6 2002 François Pons <fpons@mandrakesoft.com> 3.9-6mdk
- added --allow-nodeps and --allow-force option to urpmi.
- globing multiple media name select them all instead of error.
- answering no to remove package cause urpmi to exit immediately.
- added support for X for asking user to unselect package or to
  remove package.

* Fri Jul 26 2002 François Pons <fpons@mandrakesoft.com> 3.9-5mdk
- fixed man pages typo.
- sorted package to remove list.
- always copy rpm if using supermount on a cdrom (avoid being too slow).

* Thu Jul 25 2002 François Pons <fpons@mandrakesoft.com> 3.9-4mdk
- fixed urpmq -u.

* Wed Jul 24 2002 François Pons <fpons@mandrakesoft.com> 3.9-3mdk
- added more log.
- use perl-URPM-0.50-4mdk or better for correct generation of
  synthesis file for unresolved provides when packages are
  multiply defined.

* Tue Jul 23 2002 François Pons <fpons@mandrakesoft.com> 3.9-2mdk
- updated urpme to use perl-URPM and speed it up (no more
  rpm -e --test ...).
- updated rpm-find-leaves to use perl-URPM.
- dropped build requires to rpmtools (but need rpm >= 4.0.3).

* Tue Jul 23 2002 François Pons <fpons@mandrakesoft.com> 3.9-1mdk
- updated to use perl-URPM >= 0.50.

* Mon Jul 22 2002 François Pons <fpons@mandrakesoft.com> 3.8-3mdk
- fixed ldconfig cannot be installed.
- added translation support on error.

* Mon Jul 22 2002 François Pons <fpons@mandrakesoft.com> 3.8-2mdk
- fixed no dependencies or forced install error.

* Fri Jul 19 2002 François Pons <fpons@mandrakesoft.com> 3.8-1mdk
- removing, installing and upgrading packages is done in only
  one transaction.
- changed installation progress to look like rpm one.

* Wed Jul 17 2002 François Pons <fpons@mandrakesoft.com> 3.7-6mdk
- fixed uncatched die, now produce error message.

* Tue Jul 16 2002 François Pons <fpons@mandrakesoft.com> 3.7-5mdk
- fixed no progression of download.
- fixed bad proxy support on command line.

* Fri Jul 12 2002 Pixel <pixel@mandrakesoft.com> 3.7-4mdk
- fix problem with no proxy

* Thu Jul 11 2002 François Pons <fpons@mandrakesoft.com> 3.7-3mdk
- incorporated proxy patch of Andre Duclos <shirka@wanadoo.fr>.
- added tempory error message (before message and translation are
  done).

* Tue Jul  9 2002 Pixel <pixel@mandrakesoft.com> 3.7-2mdk
- rebuild for perl 5.8.0

* Mon Jul  8 2002 François Pons <fpons@mandrakesoft.com> 3.7-1mdk
- added new methods to handle directly installation of package (no
  more rpm binary needed).
- fixed some english typo (thanks to Mark Walker).

* Tue Jul  2 2002 Pixel <pixel@mandrakesoft.com> 3.6-5mdk
- use perl-Locale-gettext instead of perl-gettext
  (ie. Locale::gettext instead of Locale::GetText)

* Fri Jun 28 2002 François Pons <fpons@mandrakesoft.com> 3.6-4mdk
- increase retry count to 10 instead of 3 for rsync and ssh protocol.
- support prefered tools to download files (grpmi only handles ftp
  and http protocol currently).
- change behaviour of no answered to remove package to simply ignore
  remove instead of exiting.

* Fri Jun 28 2002 François Pons <fpons@mandrakesoft.com> 3.6-3mdk
- fix deadlock on removing package.
- fix rsync download for mulitples files.

* Thu Jun 27 2002 François Pons <fpons@mandrakesoft.com> 3.6-2mdk
- added rsync:// and ssh:// protocol to urpmi.

* Thu Jun 27 2002 François Pons <fpons@mandrakesoft.com> 3.6-1mdk
- removed no more used methods in urpm module.
- make sure absent synthesis force synthesis regeneration.
- add initial support to remove package wich will breaks upgrade
  for urpmi only (ignored in urpmq).

* Thu Jun 20 2002 François Pons <fpons@mandrakesoft.com> 3.5-8mdk
- added back version lost for some time (Guillaume Rousse).
- added --list to urpmq to list package.
- added regression test (explicit make test for instance).

* Wed Jun 19 2002 François Pons <fpons@mandrakesoft.com> 3.5-7mdk
- fixed urpmq to no more use old resolution methods in urpm.pm.
- fixed urpmq to take care of choices correctly (no default selection).

* Tue Jun 18 2002 François Pons <fpons@mandrakesoft.com> 3.5-6mdk
- fixed --bug on required file not provided for generating rpmdb.cz.

* Mon Jun 17 2002 François Pons <fpons@mandrakesoft.com> 3.5-5mdk
- fixed urpmi --auto-select with no update and question asked.
- fixed urpmq --auto-select with error on HASH...

* Mon Jun 17 2002 François Pons <fpons@mandrakesoft.com> 3.5-4mdk
- fixed urpmq --headers on some cases.

* Thu Jun 13 2002 François Pons <fpons@mandrakesoft.com> 3.5-3mdk
- fixed --auto-select and skip.list.

* Thu Jun 13 2002 François Pons <fpons@mandrakesoft.com> 3.5-2mdk
- added --env option to urpmi to replay bug report.

* Thu Jun 13 2002 François Pons <fpons@mandrakesoft.com> 3.5-1mdk
- use perl-URPM >= 0.04-2mdk for new require resolution algorithms.

* Mon Jun 10 2002 François Pons <fpons@mandrakesoft.com> 3.4-9mdk
- fixed no output if root.
- use message function as most as possible. (why it wasn't used ?)
- fix message to output more if bug report.
- list of package is LF separated instead of space separated.

* Mon Jun 10 2002 François Pons <fpons@mandrakesoft.com> 3.4-8mdk
- added --bug option to report bug report.
- fixed --auto-select and skip.list.

* Fri Jun  7 2002 François Pons <fpons@mandrakesoft.com> 3.4-7mdk
- fixed still present log on standard output.

* Fri Jun  7 2002 François Pons <fpons@mandrakesoft.com> 3.4-6mdk
- fixed skip.list to skip according provides (even not the best).
- fixed package id 0 always selected (generally ldconfig or lsbdev).

* Wed Jun  5 2002 François Pons <fpons@mandrakesoft.com> 3.4-5mdk
- fixed fuzzy search on package (error in urpm.pm around line 1404-1409).

* Wed Jun  5 2002 François Pons <fpons@mandrakesoft.com> 3.4-4mdk
- fixed urpmq.
- fixed incomplete requires on some cases.
- fixed reading of rpm files.

* Wed Jun  5 2002 François Pons <fpons@mandrakesoft.com> 3.4-3mdk
- avoid sub of sub with different level of variable closure in perl,
  this cause the interpreter to lose its memory usage.

* Wed Jun  5 2002 François Pons <fpons@mandrakesoft.com> 3.4-2mdk
- fix rpmdb non closed when traversing it.
- fix ftp and http medium with bad list generation.
- improved urpmi.update to avoid two pass all the time.

* Tue Jun  4 2002 François Pons <fpons@mandrakesoft.com> 3.4-1mdk
- use URPM perl module instead of rpmtools.

* Thu Apr 11 2002 François Pons <fpons@mandrakesoft.com> 3.3-25mdk
- fixed a problem for searching package according to name when
  nothing should be found but other package are proposed.

* Wed Apr 10 2002 François Pons <fpons@mandrakesoft.com> 3.3-24mdk
- fixed package that need to be upgraded but which is provided
  by another package (Mesa and XFree86-libs).

* Wed Apr 10 2002 François Pons <fpons@mandrakesoft.com> 3.3-23mdk
- fixed diff_provides on unversioned property not taken into 
  account (libbinutils2 with binutils).
- fixed virtual version only requires against virtual version and
  release provides when resolver try to check release
  (libgtk+-x11-2.0_0-devel with gtk+2.0-backend-devel).

* Mon Mar 11 2002 François Pons <fpons@mandrakesoft.com> 3.3-22mdk
- added --wget/--curl support to urpmq (needed by rpmdrake).

* Thu Mar  7 2002 François Pons <fpons@mandrakesoft.com> 3.3-21mdk
- fix --wget and --curl for urpmi.addmedia.

* Thu Mar  7 2002 François Pons <fpons@mandrakesoft.com> 3.3-20mdk
- fixed when console has been closed and urpmi ask for changing
  medium (currently it open/eject the device).

* Tue Mar  5 2002 François Pons <fpons@mandrakesoft.com> 3.3-19mdk
- fixed parse_synthesis when a the src package is following its
  binary counterpart (overidding its description).

* Mon Mar  4 2002 François Pons <fpons@mandrakesoft.com> 3.3-18mdk
- added patch from Andrej Borksenkow modified.

* Thu Feb 28 2002 François Pons <fpons@mandrakesoft.com> 3.3-17mdk
- added (undocumented) --root option to urpmi/urpmq to install in a
  given root.
- rebuild with newer po.

* Wed Feb 27 2002 François Pons <fpons@mandrakesoft.com> 3.3-16mdk
- fixed possible problem on urpmi update db (perl die workarounded).

* Mon Feb 25 2002 François Pons <fpons@mandrakesoft.com> 3.3-15mdk
- fixed not to require Fcntl module (in perl package).
- fixed bad behaviour on src package as user (no message).
- fixed src package listed on package to be installed (which is
  wrong).
- removed kernel-source in inst.list which may breaks on some
  case (workaround).

* Thu Feb 21 2002 François Pons <fpons@mandrakesoft.com> 3.3-14mdk
- build package as noarch as there is no more any binary inside.
- fixed urpme to avoid removing base package.

* Thu Feb 21 2002 François Pons <fpons@mandrakesoft.com> 3.3-13mdk
- removed staling debug log.
- try to mount a removable device before examining if an available
  device is present.

* Wed Feb 20 2002 François Pons <fpons@mandrakesoft.com> 3.3-12mdk
- fixed installing dependancies of given src.rpm filename.
- fixed to keep removable device already mounted before asking
  user to change.

* Tue Feb 19 2002 François Pons <fpons@mandrakesoft.com> 3.3-11mdk
- fixed obsoletes on direct requires when a sense is given.
- added a tracking method in urpm library for allowing upgrade.

* Mon Feb 18 2002 Pixel <pixel@mandrakesoft.com> 3.3-10mdk
- remove autoirpm until it's fixed (or used/advertised)

* Mon Feb 18 2002 François Pons <fpons@mandrakesoft.com> 3.3-9mdk
- fixed requires resolution regression when old package provides
  property removed by newer (libification).

* Mon Feb 18 2002 François Pons <fpons@mandrakesoft.com> 3.3-8mdk
- added missing build requires on rpmtools.
- fixed too verbose erroneous output that may hurt the user.
- fixed reduce_pathname with real url which reduce a bit
  too much.

* Sat Feb 16 2002 Stefan van der Eijk <stefan@eijk.nu> 3.3-7mdk
- BuildRequires

* Thu Feb 14 2002 François Pons <fpons@mandrakesoft.com> 3.3-6mdk
- use reduce_pathname even for downloading distant file.
- fixed typo.

* Wed Feb 13 2002 François Pons <fpons@mandrakesoft.com> 3.3-5mdk
- fixed source package given on command line in urpmi.
- fixed management of obsoletes in --auto-select.

* Tue Feb 12 2002 François Pons <fpons@mandrakesoft.com> 3.3-4mdk
- fixed bad method reference in urpmq (used by rpmdrake).
- fixed urpmq -d behaviour.
- fixed bad signal handler behaviour.

* Tue Feb 12 2002 François Pons <fpons@mandrakesoft.com> 3.3-3mdk
- package installed (and not upgraded) are by default using --nodeps
  (typically kernel-source).
- updated man pages.

* Mon Feb 11 2002 François Pons <fpons@mandrakesoft.com> 3.3-2mdk
- fixed multiple mounts of removable device.

* Mon Feb 11 2002 François Pons <fpons@mandrakesoft.com> 3.3-1mdk
- added --fuzzy as alias to -y (sorry Andrej to be late on this).
- added --src (aliased to -s) to handle src rpm in medium.
- added --noclean (only urpmi) to avoid cleaning the cache of rpm.
- try handling src in medium (there is still weirdness for access
  right, need to be root first and user after).

* Thu Feb  7 2002 François Pons <fpons@mandrakesoft.com> 3.2-8mdk
- fixed a requires resolution when a package C is upgraded which
  need a package A with a specific version and release, but a
  package B is already installed providing A with a better version
  and release, in such case urpmi doesn't think it is necessary
  to upgrade A.

* Thu Jan 31 2002 François Pons <fpons@mandrakesoft.com> 3.2-7mdk
- fixed regexp in supermount fstab management.
- simply kill urpmi logger which avoid losing 1 second.
- early check of installed package.
- fixed operator comparison when version are equal and operator
  is strict and release is present for conflicts, provides and
  requires tags elements.

* Wed Jan 30 2002 François Pons <fpons@mandrakesoft.com> 3.2-6mdk
- fixed some case where removable device are not ejected.

* Tue Jan 29 2002 François Pons <fpons@mandrakesoft.com> 3.2-5mdk
- added -y options to urpmi/urpmq to impose fuzzy search.
- cleaned dependancy resolver algorithm.
- fixed package asked to be installed but already installed (rare).
- fixed TERM signal send to itself.

* Mon Jan 28 2002 François Pons <fpons@mandrakesoft.com> 3.2-4mdk
- integrated patch for supermount from Andrej Borsenkow.
- fixed --wget (or --curl) not used in urpmi.update.
- try to manage .src.rpm file in a usable way.
- fixed requires resolution on multiple requires with
  sense and without sense informations on the same
  package (menu bug).
- fixed typo in po/fr.po (multiple -f for help page).

* Wed Jan 23 2002 François Pons <fpons@mandrakesoft.com> 3.2-3mdk
- fixed possible conflicts management error.
- fixed --mediums for upload of same package in different media.
- changed --mediums to --media but kept --mediums.

* Thu Jan 17 2002 François Pons <fpons@mandrakesoft.com> 3.2-2mdk
- added urpm.3 man pages.
- improved urpmi.removemedia (help, added -c flag, noclean headers).

* Wed Jan 16 2002 François Pons <fpons@mandrakesoft.com> 3.2-1mdk
- fixed bad use of update flag.
- fixed urpmi_rpm-find-leaves to use rpm db directly.
- added --mediums to urpmi/urpmq to select medium explicitely.
- added workaround to make sure synthesis file are built,
  using specific rpmtools-4.0-4mdk and above parsehdlist.
- release 3.2 (urpmi_rpm-find-leaves changes, --mediums flag).

* Wed Jan 16 2002 François Pons <fpons@mandrakesoft.com> 3.1-8mdk
- improved dependencies resolution (typically XFree86 newer
  packages).
- removed log on uploading with curl.

* Tue Jan 15 2002 François Pons <fpons@mandrakesoft.com> 3.1-7mdk
- manage conflicts for dependencies resolution.
- added conflicts tag and obsoletes tag in synthesis.

* Thu Jan 10 2002 François Pons <fpons@mandrakesoft.com> 3.1-6mdk
- fixed distant list file support.
- allow shadow approach of list file, the same list file (global)
  can be used for each intermediate medium, urpmi choose the right
  entry for each medium from the same source.
- added /./ as string marker to probe url, this means the heading
  ./ of find . -name "*.rpm" -print should be kept.

* Wed Jan  9 2002 François Pons <fpons@mandrakesoft.com> 3.1-5mdk
- added lock urpmi database features.
- added support for distant list file.

* Thu Dec 20 2001 François Pons <fpons@mandrakesoft.com> 3.1-4mdk
- make sure curl fail if http url does not exists.
- added probe for http or ftp hdlist or synthesis when adding
  a medium (-h).
- added probe for synthesis.hdlist2.cz (contrib medium).
- added signal handler when opening rpm database to make sure
  it will be closed on SIGINT or SIGQUIT.
- urpmi use -p by default.
- allow urpmq to download rpm with http or ftp protocol when
  invoked with --headers (fix rpminst behaviour).

* Mon Dec 17 2001 François Pons <fpons@mandrakesoft.com> 3.1-3mdk
- fixed choice listing.
- somewhat fixed -p kernel.
- fixed installation of package with naming convention changed to
  make upgrade identical to install (kernel and kernel-source).
- allow not to use parsehdlist during --auto-select (now disabled
  by default)
- fix curl support broken for http files and missing ftp files.

* Fri Dec 14 2001 François Pons <fpons@mandrakesoft.com> 3.1-2mdk
- added time conditionnal download to curl interface for both http
  and ftp protocol (so need Date::Manip because urpm library use it
  for ftp as no support in curl).
- updated urpm library version to 3.1.

* Thu Dec 13 2001 François Pons <fpons@mandrakesoft.com> 3.1-1mdk
- added --distrib flag to urpmi.addmedia to add all media from the
  installation medium.
- fixed update on removable medium (the second to more).
- added probe on name to select media (urpmi.update and urpmi.removemedia).
- added log when adding or removing media.
- release 3.1 (interface change, removed method in urpm library).

* Wed Dec 12 2001 François Pons <fpons@mandrakesoft.com> 3.0-6mdk
- fixed removable device probe for addition of medium.
- fixed synthesis size checking.
- added log when copying file (nfs).
- removed error when description file is not retrieved successfully.
- added -h option to urpmi.addmedia to probe for synthesis or hdlist.
- modified --force of urpmi.update to behave smootly (given once to
  force copy of file, given twice to force regeneration of hdlist).

* Mon Dec 10 2001 François Pons <fpons@mandrakesoft.com> 3.0-5mdk
- fixed %%post again.
- added kernel-source in /etc/urpmi/inst.list.

* Fri Dec  7 2001 François Pons <fpons@mandrakesoft.com> 3.0-4mdk
- fixed in urpmq to handle --headers (needed by rpminst) when
  no hdlist are present.

* Fri Dec  7 2001 François Pons <fpons@mandrakesoft.com> 3.0-3mdk
- fixed back /etc/urpmi/urpmi.cfg update.
- fixed back synthesis source management.
- fixed extraction of epoch tag for old synthesis.

* Fri Dec  7 2001 François Pons <fpons@mandrakesoft.com> 3.0-2mdk
- fixed %%post with exit code.
- removing sense data in provides (internally).
- optimized depslist relocation for provides cleaning.
- optimized synthesis parsing.
- make sure /etc/urpmi/urpmi.cfg is written on modification.

* Thu Dec  6 2001 François Pons <fpons@mandrakesoft.com> 3.0-1mdk
- 3.0 so urpm library interface change and method removal.
- depslist*, compss, provides are obsoleted, synthesis file
  are now used instead (this will help rpmdrake caching).
- added missing requires on perl for autoirpm.

* Thu Dec  6 2001 François Pons <fpons@mandrakesoft.com> 2.2-2mdk
- fixed bad reference with -p.
- changed -p ... to use choice instead of mutliple packages.

* Wed Dec  5 2001 François Pons <fpons@mandrakesoft.com> 2.2-1mdk
- match rpmtools-4.0.
- updated help on-line and fixed options invocation.
- update translation (thierry)

* Thu Nov 29 2001 François Pons <fpons@mandrakesoft.com> 2.1-7mdk
- fixed -p flag with choices.
- fixed -p kernel which may glob another kernel package.

* Wed Nov 28 2001 François Pons <fpons@mandrakesoft.com> 2.1-6mdk
- updated requires to webfetch.
- updated requires to last rpmtools needed.

* Wed Nov 28 2001 François Pons <fpons@mandrakesoft.com> 2.1-5mdk
- fixed URL with trailing slashes.
- added download log.

* Wed Nov 28 2001 François Pons <fpons@mandrakesoft.com> 2.1-4mdk
- fixed incovation of sync method even when no files to sync.
- fixed urpmq option management (-m|-M equ -du but necessary by default).
- fixed %%preun of autoirpm to check previous installation.
- added small doc in /etc/urpmi/inst.list file.

* Tue Nov 27 2001 François Pons <fpons@mandrakesoft.com> 2.1-3mdk
- added curl support (kept wget support).
- updated help for urpmi, urpmi.update and urpmi.addmedia.
- fixed bad check of urpmi.addmedium for existing name.
- avoid some error message if description is missing (not all).
- allow any prefix for url (especially removable://...).

* Tue Nov 27 2001 François Pons <fpons@mandrakesoft.com> 2.1-2mdk
- removed old optimization to get existing depslist instead
  of rebuilding it.

* Mon Nov 26 2001 François Pons <fpons@mandrakesoft.com> 2.1-1mdk
- removed obsoleted code in urpm module.
- ignore -m, -M and -c flag of urpmi/urpmq.
- fixed group display of urpmq.
- added -f for urpmq to display full package name.
- fixed -d of urpmq.
- fixed --auto-select and files of package not obsoleted but
  present in other registered package (no more selected).
- fixed call to grpmi (no more only installation).

* Wed Nov 21 2001 François Pons <fpons@mandrakesoft.com> 2.0-7mdk
- fixed missing urpmi configuration file not read.
- fixed bad output of rpm files to be installed or upgraded.
- fixed bad check of missing rpm files.

* Mon Nov 19 2001 François Pons <fpons@mandrakesoft.com> 2.0-6mdk
- fixed --auto-select and rpm file upload.

* Fri Nov 16 2001 François Pons <fpons@mandrakesoft.com> 2.0-5mdk
- added /etc/urpmi/inst.list support.

* Thu Nov 15 2001 François Pons <fpons@mandrakesoft.com> 2.0-4mdk
- first stable support for updating synthesis file.

* Mon Nov 12 2001 François Pons <fpons@mandrakesoft.com> 2.0-3mdk
- added minimal support for updating synthesis file (untested).
- fixed requires resolution bug (thanks to Borsenkow Andrej).

* Fri Nov  9 2001 François Pons <fpons@mandrakesoft.com> 2.0-2mdk
- added error message if not root.
- fixed some removable device bad regexp (to support new format).
- avoid installing source package (downloaded but ignored).

* Tue Nov  6 2001 François Pons <fpons@mandrakesoft.com> 2.0-1mdk
- no more need for removable device selection in URL (autoprobe but need removable://)
  but old description still accepted.
- fix some mount/umount problem.
- improve -m mode speed.
- obsolete -M mode (-M is still recognized on command line but same as -m).
- depslist is no more calculated with dependencies (now optional).
- everything now as 2.0 version.

* Sat Oct 27 2001 Pixel <pixel@mandrakesoft.com> 1.7-15mdk
- fix urpme with i18n (thanks to Andrej Borsenkow)
- fix urpme with regexp-like arguments (mainly things with "++") (thanks to Alexander Skwar)

* Mon Sep 24 2001 François Pons <fpons@mandrakesoft.com> 1.7-14mdk
- fixed stale rpm file (filesize set to 0) in urpmi cache.

* Wed Sep 19 2001 François Pons <fpons@mandrakesoft.com> 1.7-13mdk
- avoid possible error on trying to remove package.
- avoid error message which are more warning.

* Mon Sep 17 2001 François Pons <fpons@mandrakesoft.com> 1.7-12mdk
- fixed urpmq usage of urpm library.

* Tue Sep 11 2001 François Pons <fpons@mandrakesoft.com> 1.7-11mdk
- fixed unable to add a ftp or http medium when with_hdlist
  is set to a value without / inside.

* Tue Sep 11 2001 François Pons <fpons@mandrakesoft.com> 1.7-10mdk
- fixed error about urpmi saying package already installed.
- fixed wrong propagation of indirect updates (-m mode only).

* Mon Sep 10 2001 François Pons <fpons@mandrakesoft.com> 1.7-9mdk
- moved depslist computation out of loop of reading.

* Mon Sep  3 2001 François Pons <fpons@mandrakesoft.com> 1.7-8mdk
- updated fr man pages (pablo).
- avoid eject removable medium if --auto is given.
- avoid stat in /dev directory.

* Fri Aug 31 2001 François Pons <fpons@mandrakesoft.com> 1.7-7mdk
- added --allow-medium-change to urpmi.
- moved autoirpm french man page to autoirpm package.

* Wed Aug 29 2001 François Pons <fpons@mandrakesoft.com> 1.7-6mdk
- fixed multiple asking of same choices.
- possibly fixed array error in resolving choices.
- fixed wrong reference to fr man pages.

* Wed Aug 29 2001 François Pons <fpons@mandrakesoft.com> 1.7-5mdk
- rebuild with latest rpm.

* Thu Jul 26 2001 François Pons <fpons@mandrakesoft.com> 1.7-4mdk
- fixed tentative to always install package with -m mode.

* Wed Jul 25 2001 François Pons <fpons@mandrakesoft.com> 1.7-3mdk
- really fix crazy behaviour of --auto-select.
- fixed local packages install.

* Wed Jul 25 2001 François Pons <fpons@mandrakesoft.com> 1.7-2mdk
- fixed crazy behaviour of --auto-select that try to select
  the whole word (no filtering of installed packages).

* Mon Jul 23 2001 François Pons <fpons@mandrakesoft.com> 1.7-1mdk
- updated to use newer rpmtools 3.1.

* Mon Jul 16 2001 Daouda Lo <daouda@mandrakesoft.com> 1.6-14mdk
- resync with cvs.

* Sat Jul 14 2001  Daouda Lo <daouda@mandrakesoft.com> 1.6-13mdk
- added urpmi logrotate file 
- more macroz

* Thu Jul  5 2001 François Pons <fpons@mandrakesoft.com> 1.6-12mdk
- fixed wrong dependencies resolution for local packages
  in minimal mode.
- improved urpmf.
- updated man pages.

* Thu Jul  5 2001 François Pons <fpons@mandrakesoft.com> 1.6-11mdk
- take care of local packages.

* Wed Jul  4 2001 François Pons <fpons@mandrakesoft.com> 1.6-10mdk
- fixed bad packages installed on some cases.

* Mon Jul  2 2001 François Pons <fpons@mandrakesoft.com> 1.6-9mdk
- fixed missing rpmtools reference in urpm library.
- changed die in fatal error.

* Mon Jul  2 2001 François Pons <fpons@mandrakesoft.com> 1.6-8mdk
- fixed typo by pixel.
- fixed bad reference in urpm reported by Michael Reinsch.
- fixed dependencies for closure with old packages.
- added --update flag to urpmi.addmedia

* Thu Jun 28 2001 François Pons <fpons@mandrakesoft.com> 1.6-7mdk
- added update flag to medium.
- fixed -M algortihms with epoch (serial) uses.

* Wed Jun 27 2001 François Pons <fpons@mandrakesoft.com> 1.6-6mdk
- fix problem interpreting serial.

* Wed Jun 27 2001 François Pons <fpons@mandrakesoft.com> 1.6-5mdk
- take care of epoch (serial) for version comparison.

* Tue Jun 26 2001 François Pons <fpons@mandrakesoft.com> 1.6-4mdk
- cleaned source package extraction algorithm.

* Mon Jun 25 2001 François Pons <fpons@mandrakesoft.com> 1.6-3mdk
- reworked algorithms to search packages, added -p options to
  urpmi and urpmq.

* Thu Jun 21 2001 François Pons <fpons@mandrakesoft.com> 1.6-2mdk
- finished i18n support for urpmi.*media.

* Wed Jun 20 2001 François Pons <fpons@mandrakesoft.com> 1.6-1mdk
- simplified urpmf.
- fixed typo in %%post.
- fix i18n support and allow l10n of all error message.
- simplified error code of urpmi/urpmq.
- new version.

* Thu Jun 14 2001 François Pons <fpons@mandrakesoft.com> 1.5-41mdk
- build release for new rpm.

* Wed May 30 2001 François Pons <fpons@mandrakesoft.com> 1.5-40mdk
- avoid including bad rpm filename or with src arch.
- make sure not to reference basesystem if it does not exists.
- fixed --auto to avoid user intervention.

* Tue May 29 2001 François Pons <fpons@mandrakesoft.com> 1.5-39mdk
- fixed broken dependancies.

* Wed May 23 2001 Pixel <pixel@mandrakesoft.com> 1.5-38mdk
- really remove all group urpmi

* Wed May 23 2001 Pixel <pixel@mandrakesoft.com> 1.5-37mdk
- removed setuid bit, now stop yelling or go get f*

* Tue May 22 2001 François Pons <fpons@mandrakesoft.com> 1.5-36mdk
- fixed warning if src rpm are in repository.

* Tue May 22 2001 François Pons <fpons@mandrakesoft.com> 1.5-35mdk
- added synthesis file filtering.
- added arch chekc support.

* Tue Apr 17 2001 François Pons <fpons@mandrakesoft.com> 1.5-34mdk
- fixed sorting of list file.

* Tue Apr 17 2001 François Pons <fpons@mandrakesoft.com> 1.5-33mdk
- make sure building of synthesis files are done.
- return error if file given are wrong.

* Fri Apr 13 2001 François Pons <fpons@mandrakesoft.com> 1.5-32mdk
- fixed typo on urpmf man pages.
- fixed urpmi return exit code of grpmi on error.
- fixed cancel on medium change dialog (gurpmi or --X).

* Tue Apr 10 2001 François Pons <fpons@mandrakesoft.com> 1.5-31mdk
- fixed error on .listing file in rpms cache directory.

* Tue Apr 10 2001 François Pons <fpons@mandrakesoft.com> 1.5-30mdk
- fixed header clean-up.
- updated man pages.

* Mon Apr  9 2001 François Pons <fpons@mandrakesoft.com> 1.5-29mdk
- fixed some missing requires for -m mode.
- fixed bad search with version and release.

* Thu Apr 05 2001 François Pons <fpons@mandrakesoft.com> 1.5-28mdk
- updated man pages.
- fixed remove of synthesis file before update.
- fixed remanent rpm file in cache.

* Tue Apr  3 2001 François Pons <fpons@mandrakesoft.com> 1.5-27mdk
- added better error management.
- fixed some typo for cache management (creating /partial).

* Tue Mar 27 2001 François Pons <fpons@mandrakesoft.com> 1.5-26mdk
- added --WID=id
- let grpmi make the upload of packages.

* Mon Mar 26 2001 François Pons <fpons@mandrakesoft.com> 1.5-25mdk
- sort list file so that rpm are sorted when installed.
- increase speed for --auto-select: implies -M by default.
- added support for retrieving descriptions file.

* Mon Mar 26 2001 François Pons <fpons@mandrakesoft.com> 1.5-24mdk
- fixed annoying message when adding a medium (cp).

* Fri Mar 23 2001 François Pons <fpons@mandrakesoft.com> 1.5-23mdk
- added synthesis hdlist file support to speed up -m mode.

* Sun Mar 18 2001 Pixel <pixel@mandrakesoft.com> 1.5-22mdk
- fix for gmessage and quotes
- adapt autoirpm.update to new hdlists

* Thu Mar 15 2001 Pixel <pixel@mandrakesoft.com> 1.5-21mdk
- update urpmi_rpm-find-leaves

* Fri Mar  9 2001 François Pons <fpons@mandrakesoft.com> 1.5-20mdk
- check whatprovides by examining path too for mode -m.
- fixed incorrect requires/provides association for mode -m.

* Wed Mar  7 2001 François Pons <fpons@mandrakesoft.com> 1.5-19mdk
- fixed default -m mode for urpmq.
- added log for getting packages (wget) and installing them.
- avoid asking user if everything is already installed.

* Wed Mar  7 2001 François Pons <fpons@mandrakesoft.com> 1.5-18mdk
- fixed last line not printed for rpm output.

* Mon Mar  5 2001 François Pons <fpons@mandrakesoft.com> 1.5-17mdk
- fixed ask choices for urpmi -m mode.
- changed default behaviour to abort transaction on error.

* Mon Mar  5 2001 François Pons <fpons@mandrakesoft.com> 1.5-16mdk
- make sure to kill sub process that are doing log to
  avoid lock.

* Sat Mar  3 2001 François Pons <fpons@mandrakesoft.com> 1.5-15mdk
- urpmi mode set to -m by default.

* Thu Mar  1 2001 François Pons <fpons@mandrakesoft.com> 1.5-14mdk
- update with newer rpmtools interface.

* Tue Feb 27 2001 François Pons <fpons@mandrakesoft.com> 1.5-13mdk
- fixed removable cdrom old format extraction.
- fixed bad i18n usage.

* Tue Feb 27 2001 François Pons <fpons@mandrakesoft.com> 1.5-12mdk
- removed use of tee, now forked.

* Tue Feb 27 2001 François Pons <fpons@mandrakesoft.com> 1.5-11mdk
- fixed cohabitation of --auto-select and skip list.
- added -m mode for urpmq.
- added --sources flag for urpmq.

* Mon Feb 26 2001 François Pons <fpons@mandrakesoft.com> 1.5-10mdk
- fixed auto-select flag to use dependancies resolver after.

* Mon Feb 26 2001 François Pons <fpons@mandrakesoft.com> 1.5-9mdk
- fixed big bug of provides files completely read but only
  files should be extracted with no package description.
- added log for depslist computation.

* Fri Feb 23 2001 François Pons <fpons@mandrakesoft.com> 1.5-8mdk
- fix --auto-select and skip list.

* Fri Feb 23 2001 François Pons <fpons@mandrakesoft.com> 1.5-7mdk
- added /etc/urpmi/skip.list for package that should not
  be upgraded.
- remove -v option of urpmq to match -v as verbose.

* Mon Feb 19 2001 François Pons <fpons@mandrakesoft.com> 1.5-6mdk
- fixed urpmq --headers with exotic rpm filename.
- fixed closing using tee (need testing).
- fixed missing dependancies resolution using -m mode.

* Mon Feb 19 2001 François Pons <fpons@mandrakesoft.com> 1.5-5mdk
- fixed -m mode for prompting user if needed.
- fixed -m mode with depandancies resolving.
- avoid update urpmi db except if old urpmi.

* Fri Feb 16 2001 François Pons <fpons@mandrakesoft.com> 1.5-4mdk
- fixed -m mode with failed depandancies.

* Fri Feb 16 2001 François Pons <fpons@mandrakesoft.com> 1.5-3mdk
- added -m flag to urpmi for minimal upgrade.
- fixed urpmq olding approach of local rpm (added --force too
  as in urpmi).
- fixed some i18n usage.

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
