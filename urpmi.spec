%define group Utilities/System

Name: urpmi
Version: 1.0
Release: 1mdk
License: GPL
Source0: %{name}.tar.bz2
Summary: User mode rpm install
Requires: /usr/bin/suidperl /usr/bin/rpm2header /usr/bin/hdlist2files /usr/bin/hdlist2names /usr/bin/gendepslist eject
BuildRoot: /tmp/%{name}

Group: %{group}
%description
urpmi enable non-superuser install of rpms. In fact, it only authorizes
well-known rpms to be installed.

You can compare rpm vs. urpmi  with  insmod vs. modprobe

%changelog
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

%package -n gurpmi
Version: 0.4
Summary: User mode rpm GUI install
Requires: urpmi grpmi gchooser gmessage
Group: %{group}
%description -n gurpmi
gurpmi enable non-superuser install of rpms. In fact, it only authorizes
well-known rpms to be installed.

You can compare rpm vs. urpmi  with  insmod vs. modprobe

%package -n autoirpm
Version: 0.2
Summary: Auto install of rpm on demand
Requires: sh-utils urpmi gurpmi xtest gmessage gurpmi
Group: %{group}

%description -n autoirpm
Auto install of rpm on demand


%prep
%setup -n %{name}

%install
rm -rf $RPM_BUILD_ROOT
make PREFIX=$RPM_BUILD_ROOT install
install -d $RPM_BUILD_ROOT/var/lib/urpmi/autoirpm.scripts
install -m 644 autoirpm.deny $RPM_BUILD_ROOT/etc/urpmi

cd $RPM_BUILD_ROOT/usr/bin ; mv -f rpm-find-leaves urpmi_rpm-find-leaves

%clean
rm -rf $RPM_BUILD_ROOT
rm -rf $RPM_BUILD_DIR/$RPM_PACKAGE_NAME

%pre
groupadd -r -f urpmi

%preun -n autoirpm
autoirpm.uninstall

%files
%defattr(-,root,root)
%attr(0755, root, urpmi) %dir /etc/urpmi
%attr(0755, root, urpmi) %dir /var/lib/urpmi
%attr(4750, root, urpmi) /usr/bin/urpmi
/usr/bin/urpmi_rpm-find-leaves
/usr/bin/rpmf
/usr/sbin/urpmi.*
/usr/share/locale/*/LC_MESSAGES/urpmi.po
%doc /usr/man/man*/urpmi*

%files -n gurpmi
%defattr(-,root,root)
/usr/X11R6/bin/gurpmi

%files -n autoirpm
%defattr(-,root,root)
%dir /var/lib/urpmi/autoirpm.scripts
/etc/urpmi/autoirpm.deny
/usr/sbin/autoirpm.*
/usr/bin/_irpm
%doc README-autoirpm-icons autoirpm.README
