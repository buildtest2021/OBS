Name:           <%= @wizard_state["name"] %>
# List of additional build dependencies
#BuildRequires:  gcc-c++ libxml2-devel
Version:        <%= @wizard_state["version"] %>
Release:        1
License:        <%= @wizard_state["license"] %>
Source:         <%= @wizard_state["tarball"] %>
Group:          <%= @wizard_state["group"] %>
Summary:        <%= @wizard_state["summary"] %>
BuildRoot:      %{_tmppath}/%{name}-%{version}-build

%description
<%= @wizard_state["description"].gsub(/([^\n]{1,70})([ \t]+|\n|$)/, "\\1\n") %>

%prep
%setup

%build
# Assume that the package is built by plain 'make' if there's no ./configure.
# This test is there only because the wizard doesn't know much about the
# package, feel free to clean it up
if test -x ./configure; then
	%configure
fi
make

%install
make DESTDIR=%buildroot install

# Write a proper %%files section and remove these two commands and
# the '-f filelist' option to %%files
echo '%%defattr(-,root,root)' >filelist
find %buildroot -type f -printf '/%%P*\n' >>filelist

%clean
rm -rf %buildroot

%files -f filelist
%defattr(-,root,root)
# This is a place for a proper filelist:
# /usr/bin/<%= @wizard_state["name"] %>
# You can also use shell wildcards:
# /usr/share/<%= @wizard_state["name"] %>/*
# This installs documentation files from the top build directory
# into /usr/share/doc/...
# %doc README COPYING
# The advantage of using a real filelist instead of the '-f filelist' trick is
# that rpmbuild will detect if the install section forgets to install
# something that is listed here

%changelog
* <%= Date.today.strftime("%a %b %d %Y") %> <%= @http_user.email %>
- packaged <%= @wizard_state["name"] %> version <%= @wizard_state["version"] %> using the buildservice spec file wizard
