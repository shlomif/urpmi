Summary: x
Name: post
Version: 1
Release: 1
License: x
Group: x
Url: x

%description
x

%post -p <lua>
print("%{name}-%{version}")
exit(1)

%files
