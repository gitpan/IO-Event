package Test::XMultiFork;

use IO::Event;
use IO::Handle;
require POSIX;
use Socket;
require Exporter;
use Time::HiRes qw(sleep);

@ISA = qw(Exporter);

use strict;
use diagnostics;

# server side
my %capture;
my $sequence = 1;

# client side
my $newstdout;

sub dofork
{
	my ($pkg, $spec) = @_;

	while($spec) {
		$spec =~ s/^([a-z])(\d*)// || die "illegal fork spec";
		my $letter = $1;
		my $count = $2 || 1;
		for my $n (1..$count) {
			my $pid;
			my $psideCapture = new IO::Handle;
			$newstdout = new IO::Handle;
			socketpair($psideCapture, $newstdout, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
				|| die "socketpair: $!";
			if ($pid = fork()) {
				# parent
#sleep(0.1);
				$newstdout->close();

				if (0 && 'CRAZY_STUFF') { 
					use IO::Pipe;
					my $pipe = new IO::Pipe;

					if (fork()) {
						$newstdout->close();
						$pipe->reader();
						$psideCapture = $pipe;
					} else {
						$pipe->writer();
						my $fn = $pipe->fileno();
						open(STDOUT, ">&=$fn") || die "redirect stdout2: $!";
						$fn = $psideCapture->fileno();
						open(STDIN, "<&=", $fn) || die "redirect stdin: $!";
						exec("tee bar.$$") || die "exec: $!";
					}
				}

				Test::XMultiFork::Capture->new($psideCapture, $letter, $n);

			} elsif (defined $pid) {
				# child
				$psideCapture->close();
				for my $c (keys %capture) {
					$capture{$c}{ie}->close();
					delete $capture{$c};
				}
				if (0 && 'CRAZY_STUFF') { 
					use IO::Pipe;
					my $pipe = new IO::Pipe;

					if (fork()) {
						$newstdout->close();
						$pipe->writer();
						$newstdout = $pipe;
					} else {
						my $fn = $newstdout->fileno();
						open(STDOUT, ">&=$fn") || die "redirect stdout2: $!";
						$pipe->reader();
						$fn = $pipe->fileno();
						#close(STDIN);
						open(STDIN, "<&=", $fn) || die "redirect stdin: $!";
						exec("tee foo.$$") || die "exec: $!";
					}
				}

				$newstdout->autoflush(1);
				if (defined &Test::Builder::new) {
					my $tb = new Test::Builder;
					$tb->output($newstdout);
					$tb->todo_output($newstdout);
					$tb->failure_output($newstdout);
				}
				my $fn = $newstdout->fileno();
				open(STDOUT, ">&=$fn") || die "redirect stdout: $!";
				autoflush STDOUT 1;
				return;
			} else {
				die "Can't fork: $!";
			}
		}
	}
	if (IO::Event::loop(5) == 7.3) {
		# great
		notokay(0, "clean shutdown");
	} else {
		notokay(1, "event loop timeout");
	}
	$sequence--;
	print "1..$sequence\n";
	exit(0);
}

sub notokay
{
	my ($not, $name, $comment) = @_;
	$not = $not ? "not " : "";
	$name = " - $name" unless $name =~ /^\s*-/;
	$comment = "" unless defined $comment;
	print "${not}ok $sequence $name # $comment\n";
	$sequence++;
}

package Test::XMultiFork::Capture;

use strict;
use diagnostics;

sub new
{
	my ($pkg, $fh, $letter, $n) = @_;
	my $self = bless {
		letter	=> $letter,
		n	=> $n,
		seq	=> 1,
		plan	=> undef,
		code	=> "$letter-$n",
	}, $pkg;
	$self->{ie} = IO::Event->new($fh, $self);
	$capture{$self->{code}} = $self;
	return $self;
}

sub ie_input
{
	my ($self, $ie) = @_;
	while (<$ie>) {
		chomp;
		if (/^(?:(not)\s+)?ok\S*(?:\s+(\d+))?([^#]*)(?:#(.*))?$/) {
			my ($not, $seq, $name, $comment) = ($1, $2, $3, $4);
			$name = '' unless defined $name;
			$comment = '' unless defined $name;
			if (defined($seq)) {
				if ($seq != $self->{seq}) {
					Test::XMultiFork::notokay(1, 
						"result ordering in $self->{code}", 
						"expected '$self->{seq}' but got '$seq'");
				}
				$self->{seq} = $seq+1;
			} else {
				$self->{seq}++;
			}
			$comment .= " [ $self->{code} ]";
			Test::XMultiFork::notokay($not, $name, $comment);
			next;
		}
		if (/^1\.\.(\d+)/) {
			Test::XMultiFork::notokay(1, "multiple plans", $self->{code})
				if defined $self->{plan};
			$self->{plan} = $1;
			next;
		}
		print "$_ [$self->{code}]\n";
	}
}

sub ie_eof
{
	my ($self, $ie) = @_;
	if ($self->{plan}) {
		$self->{seq}--;
		if ($self->{plan} == $self->{seq}) {
			Test::XMultiFork::notokay(0, "plan followed", $self->{code});
		} else {
			Test::XMultiFork::notokay(1, 
				"plan followed $self->{code}",
				"plan: $self->{plan} actual: $self->{seq}");
		}
	} 
	$ie->close();
	delete $capture{$self->{code}};
	IO::Event::unloop_all(7.3) unless %capture;
}

package TheTest;

use Test::Simple;
use Time::HiRes qw(sleep);

Test::XMultiFork->dofork("a15");

srand(time ^ ($$ < 5));

import Test::Simple tests => 10;

sleep(0.1) if rand(1) < .3;
ok(1, "one$$");
sleep(0.1) if rand(1) < .3;
ok(2, "two$$");
sleep(0.1) if rand(1) < .3;
ok(3, "three$$");
sleep(0.1) if rand(1) < .3;
ok(4, "four$$");
sleep(0.1) if rand(1) < .3;
ok(5, "five$$");
sleep(0.1) if rand(1) < .3;
ok(6, "six$$");
sleep(0.1) if rand(1) < .3;
ok(7, "seven$$");
sleep(0.1) if rand(1) < .3;
ok(8, "eight$$");
sleep(0.1) if rand(1) < .3;
ok(9, "nine$$");
sleep(0.1) if rand(1) < .3;
ok(10, "ten$$");
sleep(0.1) if rand(1) < .3;

1;
