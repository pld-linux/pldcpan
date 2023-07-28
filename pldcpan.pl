#!/usr/bin/perl -w
# Requirements:
# perl-Pod-Tree perl-Archive-Any perl-Template-Toolkit perl-YAML perl-IO-String
# perl-File-Find-Rule perl-Module-CoreList

=head1 NAME

pldcpan - A Perl module packager

=head1 SYNOPSIS

    pldcpan.pl [ OPTIONS ] DIST [ DIST2 DIST3 ... ]

=head1 DESCRIPTION

This program uncompresses given archives in the current directory and -- more
or less successfully -- attempts to write corresponding perl-*.spec files.

DIST can be a directory, a compressed archive, URL to fetch or module name
(Foo::Bar) to be found on metacpan.org.

=head1 TODO

Some things we're working on/thinking about:

=over

=item 1.

use poldek to search whether dir should be packaged:

     $ poldek -q --cmd search -f /usr/share/perl5/vendor_perl/Text
     perl-base-5.8.7-4

=item 2.

first could be checked if the dir is contained by perl-base (will be faster than querying poldek)

=item 3.

Detect Module::AutoInstall and add --skipdeps to Makefile.PL.

=back

=head1 BUGS

Every software has bugs, if you find one and it's really annoying for you, try
opening bugreport at: F<http://bugs.pld-linux.org>

=head1 AUTHOR

Radoslaw Zielinski <radek@pld-linux.org>.
This manual page was composed by Elan Ruusamae <glen@pld-linux.org>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2004-2008 PLD Linux Distribution

This product is free and distributed under the Gnu Public License (GPL).

=cut


use strict;

use Cwd qw( getcwd );
use Getopt::Long qw( GetOptions );
use IPC::Run qw( run timeout );
use Pod::Select qw( podselect );
use YAML::Any qw(LoadFile);

use Pod::Tree        ();
use Archive::Any     ();
use Template         ();
use Digest::MD5      ();
use IO::String       ();
use File::Find::Rule ();
use Module::CoreList ();
use LWP::Simple      ();
use LWP::UserAgent   ();

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

our $VERSION = 1.65;
our %opts;
GetOptions(\%opts, 'verbose|v', 'modulebuild|B', 'makemaker|M', 'force');
eval "use Data::Dump qw(pp);" if $opts{verbose};
die $@                        if $@;

unless (@ARGV) {
	die <<'EOF';
usage:
	pldcpan.pl [ OPTIONS ] DIST [ DIST2 DIST3 ... ]

options:
	-v|--verbose      shout, and shout loud
	-B|--modulebuild  prefer Module::Build (default)
	-M|--makemaker    prefer ExtUtils::MakeMaker
	   --force        overwrite existing *.spec files

This program uncompresses given archives in the current directory
and -- more or less successfully -- attempts to write corresponding
perl-*.spec files.

DIST can be a directory, a compressed archive, URL to fetch or module
name (Foo::Bar) to be found on metacpan.org.

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
		  [a-z][a-z_\d]*
		  (?:
			(-)[a-z][a-z_\d]*
			(?: -[a-z][a-z_\d]*)*
		  )?
		)
		-
		v?(\d[\d._-]*[a-z]?\d*)
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
		map { $_, "$_.txt", "$_.TXT" }
		map { $_, lc $_, uc $_ }
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
	# This depends on test_find_summ_descr2
	} elsif (my $license = $info->{pod_license}) {
		$info->{license} = 'perl' if $license =~ /same terms as perl/i;
	}
	$info->{_tests}->{license} = $info->{license} ? 1 : 0;
}

sub load_META_yml {
	my $info = shift;
	return $info->{_tests}->{license}
	  if defined $info->{_tests}->{license};
	if (-f 'META.yml') {
		$info->{META_yml} = LoadFile('META.yml');
	}

	_remove_core_meta_requires($info, 'requires');
	_remove_core_meta_requires($info, 'build_requires');
	
	$info->{_tests}->{license} = $info->{META_yml} ? 1 : 0;
}

sub _remove_core_meta_requires {
	my ($info, $key) = @_;

	return if ref($info->{META_yml}->{$key}) ne 'HASH';

	# avoid perl(perl) >= 5.6... requires
	delete $info->{META_yml}->{$key}->{perl};

	while (my ($module, $version) = each %{ $info->{META_yml}->{$key} }) {
		my $result;
		print "Checking dependency: $module $version\n" if $opts{verbose};
		if ($version) {
			$result = Module::CoreList->first_release($module, $version);
		} else {
			$result = Module::CoreList->first_release($module);
		}
		# $] - perl version
		if ( $result and $result < $] ) {
			if ($opts{verbose}) {
				print "Module $module availablie in core since $result, skipping\n"
			}
			delete $info->{META_yml}->{$key}->{$module};
		}
	}
}

sub test_find_pod_file {
	my $info = shift;
	return $info->{_tests}->{find_pod_file}
	  if defined $info->{_tests}->{find_pod_file};
	die "not a directory ($info->{dir})!" unless -d $info->{dir};

	my $pod_file;

	my $mfile = @{ $info->{parts} }[-1];
	if (!defined $mfile) {
		warn " .. unable to search for \$pod_file without parts\n";
		return $info->{_tests}->{find_pod_file} = 0;
	}

	my ($pm, $pod);
	for my $f ( grep !m#/t/#, File::Find::Rule->file->name( "$mfile.pod", "$mfile.pm", )->in( $info->{dir} ) ) {
		$pod = $f if $f =~ /\.pod$/;
		$pm  = $f if $f =~ /\.pm$/;
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

	$info->{_podtree}                = $tree;
	$info->{pod_file}                = $pod_file;
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

sub test_find_summ_descr2 {
	my $info = shift;
	
	return $info->{_tests}->{find_summ_descr} = 0
	  unless test_find_pod_file($info);
	
	my $tree = $info->{_podtree};
	my $handler = _get_node_handler();
	$tree->walk( $handler );
	($info->{summary}, $info->{descr}, $info->{pod_license}) = $handler->('data');
}

# This subroutine return closure to be used as a node handler in Pod::Tree walk() method
sub _get_node_handler {
	# state informaion
	my $next_is_summary;
	my $we_are_in_license;
	my $we_are_in_description;
	my $nodes_since_description_start;
	# data we will return
	my ($summary, $description, $license);

	return sub {
		my $node = shift;

		# If not called with a node, then return collected data
		if (!ref $node) {
			$summary =~ s/^ \s* (.*?) \s* $/$1/gxm;
			return ($summary, $description, $license);
		}

		# We want to dive into root node. Note that this is the only
		# place we ever descend into tree
		return 1 if $node->is_root;

		# If we have encountered any head command then abort collecting
		# summary and description
		my $command = $node->get_command;
		if ($node->is_command and $command =~ /head/) {
			if ($command eq 'head1' or $nodes_since_description_start > 3) {
				$we_are_in_description	= 0;
			}
			$next_is_summary = 0;
			$we_are_in_license = 0;
		}

		# If previous element started an summary section, then treat
		# this one as summary text.
		if ($next_is_summary) {
			($summary = $node->get_deep_text) =~ y/\r//d;
			$summary =~ s/^\s+(.*?)\s+$/$1/;
			$next_is_summary = 0;
			return;
		}
		if ($we_are_in_license) {
			($license .= $node->get_text) =~ y/\r//d;
			return;
		}

		# If we started collecting description then add any ordinary
		# node to collected description
		if ($we_are_in_description) {
			if ($nodes_since_description_start > 5) {
				$we_are_in_description = 0;
			}
			elsif ($node->is_ordinary or $node->is_verbatim) {
				($description .= $node->get_deep_text) =~ y/\r//d;
				$nodes_since_description_start++;
			}
			else {
				return;
			}
		}
		
		# OK, next will be sumary text
		if ($node->is_c_head1 and $node->get_text =~ /^\s*NAME\s*$/) {
			$next_is_summary = 1;
		}
		# OK, description nodes will proceeed (until another head command)
		if ($node->is_c_head1 and $node->get_text =~ /DESCRIPTION/) {
			$we_are_in_description = 1;
			$nodes_since_description_start = 1;
		}
		if ($node->is_c_head1 and $node->get_text =~ /LICENSE|COPYRIGHT/) {
			$we_are_in_license = 1;
		}
		return;
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

=begin comment

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

=begin comment

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
	$info->{_tests}->{is_xs} = ( <*.c> || <*.xs> || <*/*.c> || <*/*.xs> || <*/*/*.c> || <*/*/*.xs> ) ? 1 : 0;
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

sub build_reqs_list {
	my $info = shift;
	my $rr   = $info->{META_yml}->{requires};
	my $br   = $info->{META_yml}->{build_requires};
	my %RR   = map format_r_or_br( $_, $rr->{$_} ), keys %$rr;
	my %BR   = map format_r_or_br( $_, $br->{$_} ), keys %$br;
	$info->{requires}       = \%RR;
	$info->{build_requires} = \%BR;
}

sub format_r_or_br {
	my ( $package, $version ) = @_;
	my $rpmreq = "perl($package)";
	( my $possible = "perl-$package" ) =~ s/::/-/g;
	if (   run( [ 'rpm', '-q', $possible ], \my ( undef, $out, $err ) )
		or run( [ 'rpm', '-q', '--whatprovides', $possible ], \my ( undef, $out2, $err2 ) ) )
	{
		return $possible => $version;    # we have this package or it is provided by something else
	}
	elsif ( run( [ 'rpm', '-q', '--qf', '%{NAME}\n', '--whatprovides', $rpmreq ], \my ( undef, $out3, $err3 ) ) ) {
		my @providers = grep !/^perl-(?:base|modules|devel)$/, split /\s+/, $out3;    # might be more than one
		return unless @providers;                                                     # core, ignore
		return $providers[0] => $version if @providers == 1;
	}
	return $rpmreq => $version;                                                       # fallback
}

for my $arg (@ARGV) {
	my $info = { _tests => {} };

	if (-e $arg) {
		## local file; otherwise... hackish trash code :-]
		## TODO: %pdir / %pnam in %URL
	}
	elsif (my ($tarname) =
		$arg =~ m# ^ (?:https?|ftp):// [^/]+/ (?:[^/]+/)* ([^/]+) $ #x)
	{
		$info->{url} = $arg;
		warn " -- fetching '$tarname'\n";
		my $response = LWP::Simple::mirror($info->{url}, $tarname);
		if (HTTP::Status::is_error($response)) {
			warn " !! fetching '$tarname' failed: code $response. omiting.\n";
			next;
		}
		$arg = $tarname;
	}
	elsif ($arg =~ /^[a-z\d_]+(?:(?:::|-)[a-z\d_]+)*$/i) {
		my $dist = $arg;
		$dist =~ s/-/::/g if $dist =~ /-/;
		warn " -- searching for '$dist' on metacpan.org\n";
		my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0, });
		my $scpan = $ua->get("https://fastapi.metacpan.org/v1/download_url/$dist");
		if (   !$scpan->is_success
			|| $scpan->decoded_content =~ /Not found/
			|| $scpan->decoded_content !~ m#"download_url" : ".*/authors/id/([^"]+/([^/"]+))"#)
		{
			warn " !! searching for '$dist' on metacpan.org failed: $scpan->status_line\n";
			next;
		}
		$info->{url} = "http://www.cpan.org/modules/by-authors/id/$1";
		my ($tarname) = $2;
		warn " .. found $info->{url}\n";
		my $response = LWP::Simple::mirror($info->{url}, $tarname);
		if (HTTP::Status::is_error($response)) {
			warn " !! fetching '$tarname' failed: code $response. omiting.\n";
			next;
		}
		$arg = $tarname;
	}
	else {
		warn " !! omiting '$arg': !-e or bad URL\n";
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

	$info->{dir} =~ s{/*$}{};
	die " !! not a directory: $info->{dir}" unless -d $info->{dir};
	warn " .. processing $info->{dir}\n";
	chdir $info->{dir};

#	test_find_summ_descr($info);
	test_find_summ_descr2($info);
	test_license($info);
	test_is_xs($info);
	test_has_tests($info);
	test_has_examples($info);
	test_has_doc_files($info);
	test_build_style($info);
	gen_tarname_unexp($info);
	build_reqs_list($info);

	$info->{dir} =~ s#.*/##;
	$info->{dir_unexp} = unexpand_macros($info, $info->{dir});

	# try to fixup the URL
	if ($info->{url} && $info->{url} =~ m,/by-authors/id/, && $info->{pdir}) {
		my $base_url = "http://www.cpan.org/modules/by-module/$info->{pdir}/";
		if (LWP::Simple::head($base_url . $info->{tarname})) {
			$info->{url} = $base_url . unexpand_macros($info, $info->{tarname});
		}
	}

	chdir $basedir;

	# hack for TT
	$info = {
		%$info,
		map { ; "test_$_" => $info->{_tests}->{$_} }
		  keys %{ $info->{_tests} }
	};

	pp($info) if $opts{verbose};

	die " !! I find the idea of overwriting perl.spec disgusting."
	  unless @{ $info->{parts} };
	my $spec = join('-', "$basedir/perl", @{ $info->{parts} }) . '.spec';
	warn " .. writing to '$spec'" . (-e $spec ? " ... which exists...\n" : "\n");
	die " !! I'm not to overwriting '$spec' without --force\n"
	  if -e $spec && !$opts{force};

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
#
# Conditional build:
%bcond_without	tests		# do not perform "make test"
#
%define		pdir	[% pdir %]
[% IF pnam -%]
%define		pnam	[% pnam %]
[% END -%]
Summary:	[% summary.replace('[\r\n\t ]+', ' ') |trim %]
#Summary(pl.UTF-8):	
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
[% IF url -%]
Source0:	[% url %]
[% ELSIF tarname -%]
Source0:	http://www.cpan.org/modules/by-module/[% pdir %]/[% tarname_unexp %]
[% ELSIF pnam -%]
Source0:	http://www.cpan.org/modules/by-module/[% pdir %]/%{pdir}-%{pnam}-%{version}.tar.gz
[% ELSE -%]
Source0:	http://www.cpan.org/modules/by-module/[% pdir %]/%{pdir}-%{version}.tar.gz
[% END -%]
[% IF source0md5 -%]
# Source0-md5:	[% source0md5 %]
[% END -%]
# generic URL, check or change before uncommenting
[% IF pnam -%]
#URL:		https://metacpan.org/release/[% pdir %]-[% pnam %]
[% ELSE -%]
#URL:		https://metacpan.org/release/[% pdir %]
[% END -%]
[% IF uses_module_build -%]
[% req = 'perl-Module-Build' -%]
BuildRequires:	perl-Module-Build[% ' >= ' _ build_requires.$req IF build_requires.$req %]
[% build_requires.delete('perl-Module-Build') -%]
[% END -%]
BuildRequires:	perl-devel >= 1:5.8.0
BuildRequires:	rpm-perlprov >= 4.1-13
BuildRequires:	rpmbuild(macros) >= 1.745
[% IF test_has_tests -%]
%if %{with tests}
[% FOREACH req IN requires.keys.sort -%]
BuildRequires:	[% req %][% ' >= ' _ requires.$req IF requires.$req %]
[% END -%]
[% FOREACH req IN build_requires.keys.sort -%]
[% NEXT IF requires.exists(req) -%]
BuildRequires:	[% req %][% ' >= ' _ build_requires.$req IF build_requires.$req %]
[% END -%]
%endif
[% END -%]
[% IF !test_is_xs -%]
BuildArch:	noarch
[% END -%]
BuildRoot:	%{tmpdir}/%{name}-%{version}-root-%(id -u -n)

%description
[% descr %]

# %description -l pl.UTF-8
# TODO

%prep
%setup -q -n [% dir_unexp %][% IF is_impolite %]-c[% END %]

%build
[%- IF uses_module_build %]
%{__perl} Build.PL \
[%- IF test_is_xs %]
	config="optimize='%{rpmcflags}'" \
[%- END %]
	destdir=$RPM_BUILD_ROOT \
	installdirs=vendor
./Build

%{?with_tests:./Build test}
[%- ELSIF uses_makemaker %]
%{__perl} Makefile.PL \
	INSTALLDIRS=vendor
%{__make}[% IF test_is_xs -%] \
	CC="%{__cc}" \
	OPTIMIZE="%{rpmcflags}"[% END %]

%{?with_tests:%{__make} test}
[%- ELSE %]
%{__perl} -MExtUtils::MakeMaker -wle 'WriteMakefile(NAME=>"[% parts_joined %]")' \
	INSTALLDIRS=vendor
%{__make}[% IF test_is_xs -%] \
	CC="%{__cc}" \
	OPTIMIZE="%{rpmcflags}"[% END %]

%{?with_tests:%{__make} test}
[%- END %]

%install
rm -rf $RPM_BUILD_ROOT

[% IF uses_module_build || !uses_makemaker -%]
./Build install
[% ELSE -%]
%{__make} pure_install \
	DESTDIR=$RPM_BUILD_ROOT
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
[%- number = parts.size - 1 -%]
%{perl_vendorlib}/[% parts.first(number).join('/') %]/*.pm
%{perl_vendorlib}/[% pdir %]/[% parts.last(number).join('/') %]
[% END -%]
%{_mandir}/man3/*
[% IF test_has_examples -%]
%{_examplesdir}/%{name}-%{version}
[% END -%]
