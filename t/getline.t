#!/usr/bin/perl -I.

use strict;

my $slowest = 4;

my $debug = 0;
my $c = 1;
$| = 1;
my $testcount = 100;

use Carp qw(verbose);
use Sys::Hostname;

my $startingport = 1025;

my $hostname = hostname;
my $addr = join('.',unpack('C4',gethostbyname($hostname)));
print STDERR "host = $hostname addr = $addr.\n" if $debug;

package T;

use IO::Event;
use IO::Socket::INET;
use Carp;

BEGIN {
	eval { require Time::HiRes };
	if ($@) {
		print "1..0 $@";
		exit;
	}
}

#
# basic idea...   the receiver reads something.  Once it
# has read it, it performs actions that cause more stuff
# to be sent.  The recevier stuff is called within ie_input
#

our (@tests) = (
	{
		# the first one is thrown away
	},
	{ #2
		send =>		sub {
			pusher()->print("woa baby\n");
		},
		acquire =>	sub {
			puller()->get()
		},
		compare => "woa baby",
		repeat => 1,
	},
	{ #3
		send =>		sub {
			pusher()->print("woa frog\n");
		},
		acquire =>	sub {
			puller()->getline()
		},
		compare => "woa frog\n",
		repeat => 1,
	},
	{ #4
		send =>		sub {
			my $p = pusher();
			print $p "foo\nbar\n";
		},
		acquire =>	sub {
			my $p = puller();
			return <$p>;
		},
		compare => [ "foo\n", "bar\n" ],
		repeat => 1,
		array => 1,
	},
	{ #5
		send =>		sub {
			my $p = pusher();
			printf $p "%s\n%s\n", 'foo', 'baz';
		},
		acquire =>	sub {
			my $p = puller();
			return <$p>;
		},
		compare => [ "foo\n", "baz\n" ],
		repeat => 1,
		array => 1,
	},
	{ #6
		send =>		sub {
			pusher()->print("abc123");
		},
		acquire =>	sub {
			my ($s, $ibr, $t) = @_;
			return '' unless length($$ibr) >= 6;
			my $p = puller();
			my $x;
			read($p, $x, 3);
			die unless length($x) == 3;
			read($p, $x, 3, 3);
			return $x;
		},
		compare => "abc123",
		repeat => 1,
	},
	{ #7
		send =>		sub {
			pusher()->print("a\nb\n\nc\n\n\nd\n\n\n\ne\n");
			$/ = '';
		},
		acquire =>	sub {
			my $p = puller();
			return <$p>;
		},
		compare => [ "a\nb\n\n", "c\n\n", "d\n\n", "e\n" ],
		repeat => 1,
		array => 1,
	},
	{ #8
		send =>		sub {
			pusher()->print("a\nb\n\nc\n\n\nd\n\n\n\ne\n");
			$/ = '';
		},
		acquire =>	sub {
			my $p = puller();
			my @l;
			while (<$p>) {
				push(@l, $_);
			}
			return @l;
		},
		compare => [ "a\nb\n\n", "c\n\n", "d\n\n", "e\n" ],
		repeat => 1,
		array => 1,
	},
	{ #9
		send =>		sub {
			pusher()->print("\n\n\na\nb\n\nc\n\n\nd\n\n\n\ne\n");
			$/ = "xyz";
			puller()->input_record_separator('');
		},
		acquire =>	sub {
			my $p = puller();
			return <$p>;
		},
		compare => [ "a\nb\n\n", "c\n\n", "d\n\n", "e\n" ],
		repeat => 1,
		array => 1,
	},
	{ #10
		send =>		sub {
			pusher()->print("\n\na\nb\n\nc\n\n\nd\n\n\n\ne\n");
			$/ = "xyz";
			puller()->input_record_separator('');
		},
		acquire =>	sub {
			my $p = puller();
			my @l;
			while (<$p>) {
				push(@l, $_);
			}
			return @l;
		},
		compare => [ "a\nb\n\n", "c\n\n", "d\n\n", "e\n" ],
		repeat => 1,
		array => 1,
	},
	{ #11
		send =>		sub {
			pusher()->print("xyz124abc567");
			puller()->input_record_separator(3);
		},
		acquire =>	sub {
			my $p = puller();
			my @l;
			while (<$p>) {
				push(@l, $_);
			}
			return @l;
		},
		compare => [ "xyz", "124", "abc", "567" ],
		repeat => 1,
		array => 1,
	},
	{ #12
		send =>		sub {
			pusher()->print("xyz124abc567");
			puller()->input_record_separator(3);
		},
		acquire =>	sub {
			my $p = puller();
			return <$p>;
		},
		compare => [ "xyz", "124", "abc", "567" ],
		repeat => 1,
		array => 1,
	},
	{ #13
		send =>		sub {
			pusher()->print("xyzYYY124YYYabcYYY567");
			puller()->input_record_separator("YYY");
		},
		acquire =>	sub {
			my $p = puller();
			return <$p>;
		},
		compare => [ "xyzYYY", "124YYY", "abcYYY", "567" ],
		repeat => 1,
		array => 1,
	},
	{ #14
		send =>		sub {
			pusher()->print("xyzYYY124YYYYabcYYY567");
			puller()->input_record_separator("YYY");
		},
		acquire =>	sub {
			my $p = puller();
			return <$p>;
		},
		compare => [ "xyzYYY", "124YYY", "YabcYYY", "567" ],
		repeat => 1,
		array => 1,
	},
	{ #15
		send =>		sub {
			pusher()->print("xyzYYY124YYYYabcYYY567");
			puller()->input_record_separator("YYY");
		},
		acquire =>	sub {
			my $p = puller();
			my @l;
			while (<$p>) {
				push(@l, $_);
			}
			return @l;
		},
		compare => [ "xyzYYY", "124YYY", "YabcYYY", "567" ],
		repeat => 1,
		array => 1,
	},
	{ #15
		send =>		sub {
			pusher()->print("my\ndog\nate\nmy...");
		},
		acquire =>	sub {
			my $p = puller();
			my @l;
			my $x;
			while (defined ($x = $p->get())) {
				push(@l, $x);
			}
			return @l;
		},
		compare => [ "my", "dog", "ate", "my..." ],
		repeat => 1,
		array => 1,
	},
);

printf "1..%d\n", 1+@tests;

# let's listen on a socket.  We'll expect to receive
# test numbers.  We'll print ok.

my $rp = T::pickport();
my $results = IO::Event::Socket::INET->new(
	Listen => 10,
	Proto => 'tcp',
	LocalPort => $rp,
	LocalAddr => $addr,
	Handler => 'Pull',
	Description => 'Listener',
);

die unless $results;
die unless $results->filehandle;

my $fh = $results->filehandle;
my $fn = $fh->fileno;

print STDERR "fh=$fh\n" if $debug;
print STDERR "fn=$fn\n" if $debug;

my $idle;
my $time = time;
my $waitingfor = $c;
my $ptime;

my $push_socket;
my $pull_socket;

Event->idle (
	cb => \&startup,
	reentrant => 0,
	repeat => 0,
);

okay($results, "start listening on results socket");

alarm($slowest);

print STDERR "about to loop\n" if $debug;

my $r = Event::loop();
okay($r == 7, "loop finshed ($r)");

exit(0);

sub pusher
{
	my ($np) = @_;
	$push_socket = $np if $np;
	return $push_socket;
}
sub puller
{
	my ($np) = @_;
	$pull_socket = $np if $np;
	return $pull_socket;
}


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

# support routine
sub okay
{
        my ($cond, $message) = @_;
        if ($cond) {
                print "ok $c\n";
        } else {
                if ($debug) {
                        my($package, $filename, $line, $subroutine, $hasargs, $wantarray, $evaltext, $is_require) = caller(0);
                        print "not ok $c: $filename:$line $message\n";
                } else {
                        print "not ok $c\n";
                }
        }
        $c++;
	if ($c > $testcount) {
		print STDERR "too many test results\n";
		exit(0);
	}
}

# default to oops
sub ie_input
{
	confess "we shoudn't be here";
}

sub startup
{
	IO::Event::Socket::INET->new (
		Proto => 'tcp',
		PeerPort => $rp,
		PeerAddr => $addr,
		Handler => 'Push',
	) or T::okay(0, "create pusher to $rp: $@");
}

sub sender
{
	shift(@tests);
	if (! @tests) {
		okay(1);
		exit(0);
	}
	my $t = $tests[0];
	$a = $t->{send};
	print STDERR "keys = ",join(' ',keys %$t),"\n" if $debug;
	if (ref $a) {
		eval { &$a() };
		if ($@) {
			T::okay(0, "send error $@");
			exit(0);
		}
	} else {
		pusher || confess "no pusher";
		print STDERR "printing '$a' for new test\n" if $debug;
		pusher->print($a);
	}
	print STDERR "starting test\n" if $debug;
	alarm($slowest);
}

package Push;

sub ie_connected
{
	my ($self, $s) = @_;
	T::pusher($s);
	T::sender($s);
}

sub ie_input
{
	my ($self, $s, $br) = @_;
	print $s->getlines();
}

package Pull;

sub ie_connection
{
	my ($self, $s) = @_;
	T::puller($s->accept);
}

sub ie_input
{
	my ($self, $iput, $ibuf) = @_;
	my $t = $T::tests[0];
	my $acquire = $t->{acquire};
	my ($r, @r);
	if ($t->{array}) {
		@r = eval { &$acquire($iput, $ibuf, $t) };
	} else { 
		$r = eval { &$acquire($iput, $ibuf, $t) };
	}
	if ($@) {
		T::okay(0, "acquire error $@ $!");
		exit(0);
	}
	if ($t->{repeat}) {
		if ($t->{array}) {
			unshift(@r, @{$t->{prev}})
				if $t->{prev};
			$t->{prev} = [ @r ];
		} else {
			$r = $t->{prev}.$r
				if $t->{prev};
			$t->{prev} = $r;
		}
	}
	my $compare = $t->{compare};
	my $cr;
	if (ref $compare eq 'CODE') {
		if ($t->{array}) {
			$cr = eval { &$compare(@r) };
		} else {
			$cr = eval { &$compare($r) };
		}
		if ($@) {
			T::okay(0, "copmare error $@");
			exit(0);
		}
	} elsif ($t->{array}) {
		$r = join('><', @r);
		$compare = join('><', @$compare);
		$cr = length($r) < length($compare) 
			? -1
			: ($r eq $compare
				? 0
				: 1);
	} else {
		$cr = length($r) < length($compare) 
			? -1
			: ($r eq $compare
				? 0
				: 1);
	}
	my $dr = $r;
	$dr =~ s/\n/\\n/g;
	my $dcompare = $compare;
	$dcompare =~ s/\n/\\n/g;
	if ($t->{repeat} && $cr == -1) {
		print STDERR "waiting for more input:\n\t<$dr>\n\t<$dcompare>\n"
			if $debug;
		# we'll wait for more input
		return;
	}
	T::okay($cr == 0, "comparision failed$cr:\n\t<$dr>\n\t<$dcompare>\n");
	T::sender();
}

