%include	/usr/lib/rpm/macros.perl
Summary:	PLD Linux script to create RPMS from CPAN modules
Summary(pl):	Skrypt PLD tworz±cy pakiety RPM z modu³ów z CPAN
Name:		pldcpan
Version:	1.38
Release:	1
Epoch:		0
License:	GPL
Group:		Development/Languages/Perl
Source0:	%{name}.pl
BuildRequires:	perl-ExtUtils-MakeMaker
BuildRequires:	rpm-perlprov
Requires:	perl-Data-Dump
Requires:	perl-libwww
BuildArch:	noarch
BuildRoot:	%{tmpdir}/%{name}-%{version}-root-%(id -u -n)

%description
pldcpan creates RPMs from CPAN archives, automating the locating, spec
file creation.

%description -l pl
pldcpan tworzy pakiety RPM z archiwów CPAN automatyzuj±c odnajdywanie
modu³u i tworzenie pliku spec.

%prep
# make sure we have the version we claim to have, fail otherwise
%{__perl} -MExtUtils::MM_Unix -e 'exit(ExtUtils::MM_Unix->parse_version(shift) ne shift)' %{SOURCE0} %{version}

%install
rm -rf $RPM_BUILD_ROOT

install -D %{SOURCE0} $RPM_BUILD_ROOT%{_bindir}/pldcpan

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(644,root,root,755)
%attr(755,root,root) %{_bindir}/pldcpan
