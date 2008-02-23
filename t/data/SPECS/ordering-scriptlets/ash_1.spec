Summary: ordering_ash
Name: ordering_ash
Version: 1
Release: 1
License: x
Group: x
Url: x
Provides: /bin/ash
BuildRequires: dash-static
BuildRoot: %{_tmppath}/%{name}

%install
rm -rf $RPM_BUILD_ROOT
install -D /bin/dash.static $RPM_BUILD_ROOT/bin/ash

%clean
rm -rf $RPM_BUILD_ROOT

%description
x

%files
%defattr(-,root,root)
/bin/*
