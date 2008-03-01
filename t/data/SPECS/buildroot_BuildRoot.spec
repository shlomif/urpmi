%define macro_using_buildroot $(echo %buildroot)

Summary: x
Name: buildroot_BuildRoot
Version: 1
Release: 1
License: x
Group: x
Url: x
BuildRoot: %{_tmppath}/TESTING-%{version}-%{release}

%description
x

%package sub

Summary: x
Group: x
Version: 2
Release: 2

%description sub
x

%install
%if %{rpm_version} >= 500
echo This is Mandriva specific, skipping it for rpm5.org...
%else
wanted=$(echo %{_tmppath}/TESTING-1-1 | sed 's!//!/!')
[ "%buildroot" = $wanted ] || { echo "buildroot should be $wanted instead of %buildroot"; exit 1; }
[ "$RPM_BUILD_ROOT" = $wanted ] || { echo "RPM_BUILD_ROOT should be $wanted instead of $RPM_BUILD_ROOT"; exit 1; }
[ "%macro_using_buildroot" = $wanted ] || { echo "macro_using_buildroot should be $wanted instead of %buildroot"; exit 1; }
%endif

install -d $RPM_BUILD_ROOT/etc
echo foo > $RPM_BUILD_ROOT/etc/foo

%files
/etc/foo
