Summary: a
Name: a
Version: 1
Release: 1
License: x
Group: x
Url: x
BuildRoot: %{_tmppath}/%{name}

%description
x

%build
rm -rf $RPM_BUILD_ROOT
echo "installing/upgrading %name" > README.urpmi

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
%doc README.urpmi
