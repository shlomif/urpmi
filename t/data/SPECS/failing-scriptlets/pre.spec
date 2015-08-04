Summary: x
Name: pre
Version: 1
Release: 1
License: x

%description
x

%pre -p <lua>
print("%{name}-%{version}")
exit(1)

%files
