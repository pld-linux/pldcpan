#!/usr/bin/perl -w
use strict;
use vars qw(%opts);
use Cwd qw(getcwd);
use Getopt::Long qw(GetOptions);
use IPC::Run qw(run timeout);
use Pod::Select qw(podselect);
use Pod::Tree      ();
use Archive::Any   ();
use Template       ();
use YAML           ();
use Digest::MD5    ();
use IO::String     ();
use File::Iterator ();

#use IO::All;

GetOptions(\%opts, 'verbose|v', 'modulebuild|B', 'makemaker|M');
eval "use Data::Dump qw(pp);" if $opts{verbose};
die $@                        if $@;

unless (@ARGV) {
	die <<'EOF';
usage:
	pldcpan.pl [ OPTIONS ] <list of CPAN archives>

options:
	-v|--verbose      shout, and shout loud
	-B|--modulebuild  prefer Module::Build
	-M|--makemaker    prefer ExtUtils::MakeMaker (default)

This program uncompresses given archives in the current directory
and -- more or less successfully -- attempts to write corresponding
perl-*.spec files.

$Id$
EOF
}

# get maximum information from directory name
sub test_directory {
	my $fooball = shift;
	my $info    = shift;
	return $info->{_tests}->{directory}
	  if defined $info->{_tests}->{directory};

	#	FIXME: use -v  (hmm, what did I meant?)
	unless (
		$fooball =~ m#^
		(?:.*/)?
		(
		  [a-z][a-z\d]* 
		  (?:
			([-_])[a-z][a-z\d]*
			(?: \2[a-z][a-z\d]*)*
		  )?
		)
		-
		(\d[\d._-]*[a-z]?)
		/*$ #ix
	  )
	{
		warn " -- cannot resolve name and version: '$fooball'\n";
		return $info->{_tests}->{directory} = 0;
	}

	$info->{ballname} = $1;
	$info->{namme}    = $1;
	$info->{version}  = $3;
	{
		my $separ = $2;
		@{$info}{qw(pdir pnam)} = $separ
		  ? (split /$separ/, $info->{ballname}, 2)
		  : ($info->{ballname}, undef);
		$info->{parts} =
		  [$separ ? (split /$separ/, $info->{ballname}) : ($info->{ballname})];
	}
	$info->{parts_joined} = join '::', @{ $info->{parts} };
	$info->{_tests}->{directory} = 1;
}

sub test_archive_name {
	my (undef, $info) = @_;
	return $info->{_tests}->{archive_name}
	  if defined $info->{_tests}->{archive_name};
	(my $d = shift) =~
	  s/\.(?:(?:tar\.)?(?:gz|bz2|Z)|tar|tgz|zip|rar|arj|lha)$//;
	$info->{_tests}->{archive_name} = test_directory($d, @_);
}

sub test_has_tests {
	my $info = shift;
	return $info->{_tests}->{has_tests}
	  if defined $info->{_tests}->{has_tests};
	die "not a directory ($info->{dir})!" unless -d $info->{dir};

	if (-d "$info->{dir}/t" || -f "$info->{dir}/test.pl") {
		$info->{tests}++;
		return $info->{_tests}->{has_tests} = 1;
	}
	$info->{_tests}->{has_tests} = 0;
}

sub test_has_examples {
	my $info = shift;
	return $info->{_tests}->{has_examples}
	  if defined $info->{_tests}->{has_examples};
	die "not a directory ($info->{dir})!" unless -d $info->{dir};

	$info->{examples} =
	  [grep -e,
		map { $_, lc $_, uc $_ } qw(Example Examples Eg Sample Samples)];
	$info->{_tests}->{has_examples} = @{ $info->{examples} } ? 1 : 0;
}

sub test_has_doc_files {
	my $info = shift;
	return $info->{_tests}->{has_doc_files}
	  if defined $info->{_tests}->{has_doc_files};
	die "not a directory ($info->{dir})!" unless -d $info->{dir};
	my %tmp;
	$info->{doc_files} = [
		grep -e,
		grep !$tmp{$_}++,
		map { $_, lc $_, uc $_ }
		  map { $_, "$_.txt", "$_.TXT" }
		  qw(AUTHORS BUGS ChangeLog Changes CREDITS doc docs documentation EXTRAS
		  GOALS HACKING HISTORY INSTALL NEW NEWS NOTES PATCHING README DISCLAIMER
		  ToDo)
	];
	$info->{_tests}->{has_doc_files} = @{ $info->{doc_files} } ? 1 : 0;
}

sub test_license {
	my $info = shift;
	return $info->{_tests}->{license}
	  if defined $info->{_tests}->{license};
	if (load_META_yml($info) && $info->{META_yml}->{license}) {
		$info->{license} =
		  $info->{META_yml}->{license} =~ /^l?gpl$/
		  ? uc $info->{META_yml}->{license}
		  : $info->{META_yml}->{license};
	}
	$info->{_tests}->{license} = $info->{license} ? 1 : 0;
}

sub load_META_yml {
	my $info = shift;
	return $info->{_tests}->{license}
	  if defined $info->{_tests}->{license};
	if (-f 'META.yml') {
		$info->{META_yml} = YAML::LoadFile('META.yml');
	}
	$info->{_tests}->{license} = $info->{META_yml} ? 1 : 0;
}

sub test_find_pod_file {
	my $info = shift;
	return $info->{_tests}->{find_pod_file}
	  if defined $info->{_tests}->{find_pod_file};
	die "not a directory ($info->{dir})!" unless -d $info->{dir};

	my $pod_file;

	my $mfile = (reverse @{ $info->{parts} })[0];
	my $it    = File::Iterator->new(
		DIR     => $info->{dir},
		RECURSE => 1,
		FILTER  => sub { $_[0] =~ m#(?:^|/)\Q$mfile\E\.(?:pod|pm)$# }
	);
	my ($pm, $pod);
	while (local $_ = $it->next()) {
		$pod = $_ if /\.pod$/;
		$pm  = $_ if /\.pm$/;
	}
	$pod_file = $pod ? $pod : $pm;
	if (   !$pod_file
		&& load_META_yml($info)
		&& exists $info->{META_yml}->{version_from})
	{
		$pod_file = $info->{META_yml}->{version_from};
	}

	unless ($pod_file) {
		warn " -- no \$pod_file <@{$info->{parts}}>\n";
		return $info->{_tests}->{find_pod_file} = 0;
	}

	my $tree = new Pod::Tree;
	$tree->load_file($pod_file);
	unless ($tree->has_pod) {
		warn " ,, no POD in $pod_file\n";
		return $info->{_tests}->{find_pod_file} = 0;
	}

	$info->{pod_file} = $pod_file;
	$info->{_tests}->{find_pod_file} = 1;
}

# workaround for Pod::Parser not supporting "\r\n" line endings
{
	no warnings 'redefine';

	sub Pod::Parser::preprocess_line {
		(my $text = $_[1]) =~ y/\r//d;
		$text;
	}
}

sub test_find_summ_descr {
	my $info = shift;
	return $info->{_tests}->{find_summ_descr}
	  if defined $info->{_tests}->{find_summ_descr};
	return $info->{_tests}->{find_summ_descr} = 0
	  unless test_find_pod_file($info);

	#	my $parser = new Pod::Select;
	#	$parser->parse_from_file($info->{pod_file});
	for my $sec ({ h => 'summary', s => 'NAME' },
		{ h => 'descr', s => 'DESCRIPTION' })
	{
		my $H = new IO::String \$info->{ $sec->{h} };
		podselect({ -output => $H, -sections => [$sec->{s}] },
			$info->{pod_file});
		$H->close;
		$info->{ $sec->{h} } =~ s/^\s*=head.*//;
	}

=pod
	my $tree = new Pod::Tree;
	$tree->load_file($info->{pod_file});
	unless ($tree->has_pod) {
		warn " ,, no POD in $info->{pod_file}\n";
		return $info->{_tests}->{find_summ_descr} = 0;
	}

	my $root = $tree->get_root;
	$info->{$_} = '' for qw/summary descr/;

	my $state;
	for my $n (@{ $root->get_children }) {
		if ($n->is_c_head1) {
			undef $state;
			$state = 'summary'
			  if $n->get_text =~ /^\s*NAME\b/ && !$info->{summary};
			$state = 'descr'
			  if $n->get_text =~ /^\s*DESCRIPTION\b/ && !$info->{descr};
			next;
		}
		$info->{$state} .= $n->get_text if $state;
	}
=cut

	$info->{summary} =~ y/\r\n\t /    /s;
	$info->{$_} =~ s/^\s+|\s+$//g for qw/summary descr/;

	warn " ,, no summary in $info->{pod_file}\n"     unless $info->{summary};
	warn " ,, no description in $info->{pod_file}\n" unless $info->{descr};

=pod
	my $file < io($info->{pod_file});
	$file =~ y/\r//d;
	if ($file =~ /(?:^|\n)=head\d\s+NAME[\t ]*\n\s*(.+)\n+(?:=|$)/) {
		$info->{summary} = $1;
		$info->{summary} =~ s/\s+$//g;
	}
	else {
		warn " ,, no summary: $_\n";
		$info->{summary} = '';
	}
	if ($file =~ /\n=head\d DESCRIPTION\s*\n\s*((?:(?<!=head).+\n){1,15})/) {
		$info->{descr} = $1;
		my $tmp;
		run ['fmt'], \$info->{descr}, \$tmp;
		$info->{descr} = $tmp if length $tmp;
		$info->{descr} =~ s/\s+$//g;
	}
	else {
		warn " ,, no description: $_\n";
		$info->{descr} = '';
	}
=cut

	$info->{_tests}->{find_summ_descr} =
	  ($info->{summary} || $info->{descr}) ? 1 : 0;
}

sub test_build_style {
	my $info = shift;
	return $info->{_tests}->{build_style}
	  if defined $info->{_tests}->{build_style};
	$info->{uses_makemaker}    = -e 'Makefile.PL';
	$info->{uses_module_build} = -e 'Build.PL';
	$info->{uses_makemaker}    = 0
	  if $opts{modulebuild} && $info->{uses_module_build};
	$info->{uses_module_build} = 0
	  if $opts{makemaker} && $info->{uses_makemaker};
	$info->{_tests}->{build_style} =
	  ($info->{uses_module_build} || $info->{uses_makemaker}) ? 1 : 0;
}

sub gen_tarname_unexp {
	my $info = shift;
	return
	  unless exists $info->{tarname} && test_directory($info->{dir}, $info);
	(my $tmp = $info->{tarname}) =~ s#.*/##;
	$info->{tarname_unexp} = unexpand_macros($info, $tmp);
}

sub unexpand_macros {
	my $info  = shift;
	my $value = shift;
	$value =~ s/\Q$info->{pdir}\E/%{pdir}/;
	$value =~ s/\Q$info->{pnam}\E/%{pnam}/ if $info->{pnam};
	$value =~ s/\Q$info->{version}\E/%{version}/;
	$value;
}

sub test_is_xs {
	my $info = shift;
	return $info->{_tests}->{is_xs}
	  if defined $info->{_tests}->{is_xs};

	# Ugly bitch.
	$info->{_tests}->{is_xs} = (<*.c> || <*.xs>) ? 1 : 0;
}

sub run_configure {
	my $info = shift;
	test_build_style($info);
	return $info->{_tests}->{run_configure}
	  if defined $info->{_tests}->{run_configure};

	$info->{tmp_destdir} = getcwd() . "/pldcpan_destdir_$$";
	system(qw(rm -rf), $info->{tmp_destdir}) if -e $info->{tmp_destdir};
	my @cmd;
	if ($info->{_tests}->{build_style}) {
		@cmd =
		  $info->{uses_makemaker}
		  ? qw(perl Makefile.PL INSTALLDIRS=vendor)
		  : (
			qw(perl Build.PL installdirs=vendor config="optimize='%{rpmcflags}'"),
			qw(destdir='$info->{tmp_destdir}')
		  );
	}
	else {
		@cmd = (
			qw(perl -MExtUtils::MakeMaker -wle),
			qq#WriteMakefile(NAME=>"$info->{parts_joined}")#,
			qw(INSTALLDIRS=>vendor)
		);
	}
	$info->{_tests}->{run_configure} = run \@cmd, \undef, \my $out, \my $err,
	  timeout(20);
}

sub run_build {
	my $info = shift;
	return $info->{_tests}->{run_build} if defined $info->{_tests}->{run_build};
	return $info->{_tests}->{run_build} = 0 unless run_configure($info);

	my @cmd;
	if ($info->{_tests}->{build_style}) {
		@cmd =
		  $info->{uses_makemaker}
		  ? qw(make)
		  : qw(perl ./Build);
	}
	else {
		@cmd = qw(make);
	}
	$info->{_tests}->{run_build} = run \@cmd, \undef, \my $out, \my $err,
	  timeout(60);
}

sub run_test {
	my $info = shift;
	return $info->{_tests}->{run_test} if defined $info->{_tests}->{run_test};
	return $info->{_tests}->{run_test} = 0 unless run_build($info);

	my @cmd;
	if ($info->{_tests}->{build_style}) {
		@cmd =
		  $info->{uses_makemaker}
		  ? qw(make test)
		  : qw(perl ./Build test);
	}
	else {
		@cmd = qw(make test);
	}
	$info->{_tests}->{run_test} = run \@cmd, \undef, \my $out, \my $err,
	  timeout(360);
}

sub run_install {
	my $info = shift;
	return $info->{_tests}->{run_install}
	  if defined $info->{_tests}->{run_install};
	return $info->{_tests}->{run_install} = 0 unless run_build($info);

	my @cmd;
	if ($info->{_tests}->{build_style}) {
		@cmd =
		  $info->{uses_makemaker}
		  ? (qw(make install), "DESTDIR='$info->{tmp_destdir}'")
		  : qw(perl ./Build install);
	}
	else {
		@cmd = (qw(make install), "DESTDIR='$info->{tmp_destdir}'");
	}
	die "nfy";
}

sub find_files {
	my $info = shift;
	return $info->{_tests}->{find_files}
	  if defined $info->{_tests}->{find_files};
	return $info->{_tests}->{find_files} = 0 unless run_install($info);
	die "nfy";
}

for my $arg (@ARGV) {
	my $info = { _tests => {} };

	if (!-e $arg) {
		warn "$arg does not exist!\n";
		next;
	}

	if (-d $arg) {
		$info->{dir} = $arg =~ m#^/# ? $arg : getcwd() . "/$arg";
		test_directory($arg, $info);
	}
	else {
		open my $fh, $arg or die "can't open <$arg>: $!";
		$info->{source0md5} = Digest::MD5->new->addfile($fh)->hexdigest;
		close $fh or die "close <$arg>: $!";

		$info->{tarname} = $arg;
		my $arch = Archive::Any->new($arg);
		unless ($arch) {
			warn " -- unpacking failed, omiting $arg";
			next;
		}
		if ($arch->is_naughty) {
			warn " !! Archive::Any says, that $arg is_naughty. omiting.\n";
			next;
		}
		test_archive_name($arg, $info);
		if ($info->{is_impolite} = $arch->is_impolite) {
			if (!$info->{_tests}->{archive_name}) {
				warn
				  "test_archive_name failed and $arg is_impolite; giving up\n";
				next;
			}
			$info->{dir} = getcwd() . "/$info->{ballname}-$info->{version}";
			mkdir $info->{dir} or die "can't mkdir <$info->{dir}>, $arg!";
			$arch->extract($info->{dir}) or die "Ni! $arg\n";
		}
		else {
			($arch->files)[0] =~ m#^(?:\.?/)?([^/]+)(?:/|$)#
			  or die "can't resolve dir from content of $arg";
			$info->{dir} = getcwd() . "/$1";
			$arch->extract or die "Nii! $arg\n";
		}
	}

	test_find_pod_file($info);

	my $basedir = getcwd;

	$info->{dir} =~ s#/*$##;
	die " !! not a directory: $info->{dir}" unless -d $info->{dir};
	warn " .. processing $info->{dir}\n";
	chdir $info->{dir};

	test_find_summ_descr($info);
	test_license($info);
	test_is_xs($info);
	test_has_tests($info);
	test_has_examples($info);
	test_has_doc_files($info);
	test_build_style($info);
	gen_tarname_unexp($info);

	$info->{dir} =~ s#.*/##;
	$info->{dir_unexp} = unexpand_macros($info, $info->{dir});

	chdir $basedir;

	# hack for TT
	$info = {
		%$info,
		map { ; "test_$_" => $info->{_tests}->{$_} }
		  keys %{ $info->{_tests} }
	};

	pp($info) if $opts{verbose};

	my $spec = join('-', "$basedir/perl", @{ $info->{parts} }) . '.spec';
	warn " .. writing to $spec\n";

	my $rotfl = tell DATA;
	my $tmpl  =
	  Template->new(
		{ INTERPOLATE => 0, POST_CHOMP => 0, EVAL_PERL => 1, ABSOLUTE => 1 });
	$tmpl->process(\*DATA, $info, $spec)
	  || warn "error parsing $info->{dir}: "
	  . $tmpl->error->type . "\n"
	  . $tmpl->error->info . "\n"
	  . $tmpl->error . "\n";
	seek DATA, $rotfl, 0;
}

# vim: ts=4 sw=4 noet noai nosi cin
__DATA__
# $[% 'Revision:$, $Date'%]:$
#
# Conditional build:
%bcond_without	tests		# do not perform "make test"
#
%include	/usr/lib/rpm/macros.perl
%define	pdir	[% pdir %]
[% IF pnam -%]
%define	pnam	[% pnam %]
[% END -%]
Summary:	[% summary %]
#Summary(pl):	
Name:		perl-[% pdir %][% IF pnam %]-[% pnam %][% END %]
Version:	[% version %]
Release:	1
[% IF test_license && license == 'perl' -%]
# same as perl
License:	GPL v1+ or Artistic
[% ELSIF test_license -%]
License:	[% license %]
[% ELSE -%]
# same as perl (REMOVE THIS LINE IF NOT TRUE)
#License:	GPL v1+ or Artistic
[% END -%]
Group:		Development/Languages/Perl
[% IF tarname -%]
Source0:	http://www.cpan.org/modules/by-module/[% pdir %]/[% tarname_unexp %]
[% ELSIF pnam -%]
Source0:	http://www.cpan.org/modules/by-module/[% pdir %]/%{pdir}-%{pnam}-%{version}.tar.gz
[% ELSE -%]
Source0:	http://www.cpan.org/modules/by-module/[% pdir %]/%{pdir}-%{version}.tar.gz
[% END -%]
[% IF source0md5 -%]
# Source0-md5:	[% source0md5 %]
[% END -%]
BuildRequires:	perl-devel >= 1:5.8.0
BuildRequires:	rpm-perlprov >= 4.1-13
[% IF test_has_tests -%]
%if %{with tests}
[% FOREACH req = META_yml.requires, META_yml.build_requires -%]
BuildRequires:	perl([% req.key %])[%IF req.value%] >= [% req.value %][%END%]
[% END -%]
%endif
[% END -%]
[% IF !test_is_xs -%]
BuildArch:	noarch
[% END -%]
BuildRoot:	%{tmpdir}/%{name}-%{version}-root-%(id -u -n)

%description
[% descr %]

# %description -l pl
# TODO

%prep
%setup -q -n [% dir_unexp %][% IF is_impolite %]-c[% END %]

%build
[% IF uses_makemaker -%]
%{__perl} Makefile.PL \
	INSTALLDIRS=vendor
%{__make}[% IF test_is_xs -%] \
	OPTIMIZE="%{rpmcflags}"[% END %]

%{?with_tests:%{__make} test}
[% ELSIF uses_module_build -%]
%{__perl} Build.PL \
[% IF test_is_xs %]	config="optimize='%{rpmcflags}'" \[% END -%]
	destdir=$RPM_BUILD_ROOT \
	installdirs=vendor
./Build

%{?with_tests:./Build test}
[% ELSE -%]
%{__perl} -MExtUtils::MakeMaker -wle 'WriteMakefile(NAME=>"[% parts_joined %]")' \
	INSTALLDIRS=vendor
%{__make}[% IF test_is_xs -%] \
	OPTIMIZE="%{rpmcflags}"[% END %]

%{?with_tests:%{__make} test}
[% END -%]

%install
rm -rf $RPM_BUILD_ROOT

[% IF uses_makemaker || !uses_module_build -%]
%{__make} install \
	DESTDIR=$RPM_BUILD_ROOT
[% ELSE -%]
./Build install
[% END -%]
[% IF test_has_examples -%]

install -d $RPM_BUILD_ROOT%{_examplesdir}/%{name}-%{version}
[% FOREACH eg = examples -%]
cp -a [% eg %] $RPM_BUILD_ROOT%{_examplesdir}/%{name}-%{version}
[% END -%]
[% END -%]

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(644,root,root,755)
[% IF test_has_doc_files -%]
%doc[% FOREACH doc = doc_files %] [% doc %][% END %]
[% END -%]
[% IF test_is_xs -%]
%{perl_vendorarch}/[% pdir %]/*.pm
%dir %{perl_vendorarch}/auto/[% pdir %]/[% pnam %]
%{perl_vendorarch}/auto/[% pdir %]/[% pnam %]/*.bs
%attr(755,root,root) %{perl_vendorarch}/auto/[% pdir %]/[% pnam %]/*.so
[% ELSE -%]
%{perl_vendorlib}/[% pdir %]/*.pm
%{perl_vendorlib}/[% pdir %]/[% pnam %]
[% END -%]
%{_mandir}/man3/*
[% IF test_has_examples -%]
%{_examplesdir}/%{name}-%{version}
[% END -%]

%define	date	%(echo `LC_ALL="C" date +"%a %b %d %Y"`)
%changelog
* %{date} PLD Team <feedback@pld-linux.org>
All persons listed below can be reached at <cvs_login>@pld-linux.org

$[%'Log:'%]$
