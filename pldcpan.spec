%include	/usr/lib/rpm/macros.perl
Summary:	PLD Linux script to create RPMS from CPAN modules
Name:		pldcpan
Version:	1.23
Release:	0.1
Epoch:		0
License:	GPL
Group:		Development/Languages/Perl
Source0:	%{name}.pl
BuildArch:	noarch
BuildRoot:	%{tmpdir}/%{name}-%{version}-root-%(id -u -n)

%description
pldcpan creates RPMs from CPAN archives, automating the locating, spec
file creation.

%prep
%setup -q -c -T
install %{SOURCE0} .

%install
rm -rf $RPM_BUILD_ROOT
install -d $RPM_BUILD_ROOT%{_bindir}

install pldcpan.pl $RPM_BUILD_ROOT%{_bindir}/pldcpan

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(644,root,root,755)
%attr(755,root,root) %{_bindir}/pldcpan
