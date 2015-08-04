Summary: x
Name: posttrans
Version: 1
Release: 1
License: x
Group: x

%description
x

%posttrans -p <lua>
print("%{name}-%{version}")
exit(1)

%files
