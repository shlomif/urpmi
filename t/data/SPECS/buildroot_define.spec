%define macro_using_buildroot $(echo %buildroot)

%define buildroot %{_tmppath}/TESTING

Summary: x
Name: buildroot_define
Version: 1
Release: 1
License: x
Group: x
Url: x

%description
x

%package sub

Summary: x
Group: x
Version: 2

%description sub
x


%install
wanted=%{_tmppath}/TESTING
[ "%buildroot" = $wanted ] || { echo "buildroot should be $wanted instead of %buildroot"; exit 1; }
[ "$RPM_BUILD_ROOT" = $wanted ] || { echo "RPM_BUILD_ROOT should be $wanted instead of $RPM_BUILD_ROOT"; exit 1; }
[ "%macro_using_buildroot" = $wanted ] || { echo "macro_using_buildroot should be $wanted instead of %buildroot"; exit 1; }

install -d $RPM_BUILD_ROOT

%files
