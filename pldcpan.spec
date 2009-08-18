#
# Conditional build:
%bcond_with	autodeps	# BR packages needed only for resolving deps
#
%include	/usr/lib/rpm/macros.perl
Summary:	PLD Linux script to create RPMS from CPAN modules
Summary(pl.UTF-8):	Skrypt PLD tworzący pakiety RPM z modułów z CPAN
Name:		pldcpan
Version:	1.58
Release:	1
License:	GPL
Group:		Development/Languages/Perl
Source0:	%{name}.pl
BuildRequires:	perl-ExtUtils-MakeMaker
BuildRequires:	perl-tools-pod
BuildRequires:	rpm-perlprov >= 4.1-13
%if %{with autodeps}
BuildRequires:	perl-Archive-Any
BuildRequires:	perl-Digest-MD5
BuildRequires:	perl-File-Iterator
BuildRequires:	perl-IO-String
BuildRequires:	perl-IPC-Run
BuildRequires:	perl-Module-CoreList
BuildRequires:	perl-Pod-Tree
BuildRequires:	perl-Template-Toolkit
BuildRequires:	perl-YAML
%endif
Requires:	perl-Data-Dump
Requires:	perl-Encode
Requires:	perl-libwww
BuildArch:	noarch
BuildRoot:	%{tmpdir}/%{name}-%{version}-root-%(id -u -n)

%description
pldcpan creates RPMs from CPAN archives, automating the locating, spec
file creation.

%description -l pl.UTF-8
pldcpan tworzy pakiety RPM z archiwów CPAN automatyzując odnajdywanie
modułu i tworzenie pliku spec.

%prep
%setup -qcT
# make sure we have the version we claim to have, fail otherwise
ver=$(%{__perl} -MExtUtils::MM_Unix -e 'print ExtUtils::MM_Unix->parse_version(shift)' %{SOURCE0})
if [ "$ver" != "%{version}" ]; then
	: Update Version to $ver, and retry
	exit 1
fi
install %{SOURCE0} .

%build
pod2man -c "" pldcpan.pl > pldcpan.1

%install
rm -rf $RPM_BUILD_ROOT
install -d $RPM_BUILD_ROOT{%{_bindir},%{_mandir}/man1}
install pldcpan.pl $RPM_BUILD_ROOT%{_bindir}/pldcpan
cp -a pldcpan.1 $RPM_BUILD_ROOT%{_mandir}/man1

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(644,root,root,755)
%attr(755,root,root) %{_bindir}/pldcpan
%{_mandir}/man1/pldcpan.1*
