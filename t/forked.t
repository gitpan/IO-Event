#!/usr/bin/perl -I.

use strict;
use warnings;

my $smallsleep = 0.0001;
my $bigsleep = 0.2;
my $debug = 0;
my $inactivity = 5;

BEGIN	{
	unless (eval { require Test::More; }) {
		print "1..0 # Skipped: must have Test::More installed\n";
		exit;
	}
}

BEGIN	{
	if (eval { require Time::HiRes }) {
		import Time::HiRes qw(sleep);
	} else {
		$bigsleep = 1;
		$smallsleep = 0;
	}
}

use Event;
use IO::Event;
use IO::Socket::INET;
use Carp qw(verbose);
use Sys::Hostname;

my @tests;
my $testcount;

BEGIN {
	@tests = (
		{ #0
			repeat	=> 5,
			desc	=> "lines end in \\n",
			receive	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				my $got = <$ieo>;
				return $got;
			},
			results => [
				"howdy\n",
				"doody",
			],
			sendqueue => [
				"how",
				"dy\n",
				"doo",
				"dy"
			],
		},
		{ #1
			repeat	=> 5,
			desc	=> "paragraph mode",
			setup	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				$ieo->input_record_separator('');
			},
			receive	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				my $got = <$ieo>;
				return $got;
			},
			results => [
				"this is a test\n\n",
				"a\nb\n\n",
				"c\n\n",
				"d\n\n",
				"e\n",
			],
			sendqueue => [
				"this is ",
				"a test\n",
				"\n",
				"a\nb\n\nc\n\n\nd\n\n\n\ne\n",
			],
		},
		{ #2
			repeat	=> 5,
			desc	=> "paragraph mode, getlines",
			setup	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				$ieo->input_record_separator('');
			},
			receive	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				my (@got) = <$ieo>;
				return undef unless @got;
				return \@got;
			},
			results => [
				[ "this is a test\n\n", ],
				[ "a\nb\n\n", "c\n\n", "d\n\n", ],
				[ "e\n", ],
			],
			sendqueue => [
				"this is ",
				"a test\n",
				"\n",
				"a\nb\n\nc\n\n\nd\n\n\n\ne\n",
			],
		}, 
		{ #3
			repeat	=> 5,
			desc	=> "paragraph mode, getline, \$/ set funny",
			setup	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				$/ = 'xyz';
				$ieo->input_record_separator('');
			},
			receive	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				return <$ieo>;
			},
			results => [
				"this is a test\n\n",
				"a\nb\n\n", 
				"c\n\n", 
				"d\n\n", 
				"e\n", 
			],
			sendqueue => [
				"this is ",
				"a test\n",
				"\n",
				"a\nb\n\nc\n\n\nd\n\n\n\ne\n",
			],
		}, 
		{ #2
			repeat	=> 5,
			desc	=> "paragraph mode, getlines, \$/ set funny",
			setup	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				$/ = 'abc';
				$ieo->input_record_separator('');
			},
			receive	=> sub {
				my $serverTest = shift;
				my $ieo = shift;
				my (@got) = <$ieo>;
				return undef unless @got;
				return \@got;
			},
			results => [
				[ "this is a test\n\n", ],
				[ "a\nb\n\n", "c\n\n", "d\n\n", ],
				[ "e\n", ],
			],
			sendqueue => [
				"this is ",
				"a test\n",
				"\n",
				"a\nb\n\nc\n\n\nd\n\n\n\ne\n",
			],
		}, 
	);

	#splice(@tests, 0, 4);
	#$tests[0]->{repeat} = 1;

	$testcount = 0;
	for my $t (@tests) {
		my $subtests = scalar(@{$t->{results}}) + 1;
		$testcount += $t->{repeat} > 0 ? $t->{repeat} * $subtests : $subtests;
	}
}
BEGIN {
	use Test::More tests => $testcount;
}

my $startingport = 1025;

my $hostname = hostname;
my $addr = join('.',unpack('C4',gethostbyname($hostname)));
print STDERR "# host = $hostname, addr = $addr.\n" if $debug;

my $rp = pickport();
my $child;
my $timer;

$SIG{PIPE} = sub { 
	print "# SIGPIPE recevied in $$\n";
};

if ($child = fork()) {
	print "# PARENT $$ will listen at $addr:$rp\n" if $debug;
	my $listener = IO::Event::Socket::INET->new(
		Listen => 10,
		Proto => 'tcp',
		LocalPort => $rp,
		LocalAddr => $addr,
		Handler => new Server,
		Description => 'Listener',
	);

	$timer = Timer->new();

	$Event::DIED = sub {
		Event::verbose_exception_handler(@_);
		Event::unloop_all();
	};

	print "looping\n";
	Event::loop();
	print "done looping\n";
} elsif (defined($child)) {
	print "# CHILD $$ will connect to $addr:$rp\n" if $debug;
	while (@tests) {
		sleep($bigsleep);
		my $test = $tests[0] || last;
		shift @tests 
			if --$test->{repeat} < 1;
		print "# test $test->{desc}\n";
		my $s = IO::Socket::INET->new(
			PeerAddr => $addr,
			PeerPort => $rp,
			Proto => 'tcp',
		);
		die "$$ could not connect: $!" unless $s;
		die "$$ socket not open" if eof($s);
		my $go = <$s>;
		$go =~ s/\n/\\n/g;
		# print "# got '$go'\n";
		for (my $sqi = 0; $sqi <= $#{$test->{sendqueue}}; $sqi++) {
			sleep($smallsleep);
			if ($debug) {
				my $x = $test->{sendqueue}[$sqi];
				$x =~ s/\n/\\n/g;
				print "# SENDING '$x'\n";
			}
			(print $s $test->{sendqueue}[$sqi]) || die "print $$: $!\n";
		}
		print "# CHILD closing\n";
		close($s);
	}
} else {
	die "fork: $!";
}

exit 0;

# support routine
sub pickport
{
	for (my $i = 0; $i < 1000; $i++) {
		my $s = new IO::Socket::INET (
			Listen => 1,
			LocalPort => $startingport,
		);
		if ($s) {
			$s->close();
			return $startingport++;
		}
		$startingport++;
	}
	die "could not find an open port";
}


package Server;

use Test::More;

sub new
{
	my $pkg = shift;
	return bless { @_ };
}

sub ie_connection
{
	my ($self, $s) = @_;
	$timer->reset;
	my $serverTest = new Server;
	my $stream = $s->accept($serverTest);
	$serverTest->{stream} = $stream;
	$serverTest->{rqi} = 0;
	my $test = $tests[0];
	shift @tests 
		if --$test->{repeat} < 1;
	@$serverTest{keys %$test} = values %$test;
	my $setup = $serverTest->{setup};
	&$setup($serverTest, $stream) if $setup;
	# print "# ACCEPTED CONNECTION\n" if $debug;
	print $stream "go\n";
}

sub ie_input
{
	my ($self, $s) = @_;
	my $rec = $self->{receive};
	die unless $rec;
	for (;;) {
		my $r = &$rec($self, $s);
		return unless defined $r;
		my $expect = $self->{results}[$self->{rqi}++];
		is_deeply($r, $expect);
	}
}

sub ie_eof
{
	my ($self, $s) = @_;
	is($self->{rqi}, scalar(@{$self->{results}}));
	$s->close();
	exit 0 unless @tests;
}

package Timer;

use Carp;
use strict;
use warnings;

sub new
{
	my ($pkg) = @_;
	my $self = bless { }, $pkg;

	$self->{event} = Event->timer(
		cb		=> [ $self, 'timeout' ],
		interval	=> $inactivity,
		hard		=> 0,
	);
	return $self;
}

sub timeout
{
	print STDERR "Timeout\n";
	kill 9, $child;
	Event::unloop_all(7.2);
	exit(1);
}

sub reset
{
	my ($self) = @_;
	$self->{event}->stop();
	$self->{event}->again();
}

__END__

