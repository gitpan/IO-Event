#!/usr/bin/perl

my $pidbase = '/var/run/rinetd';
my $configfile = '/etc/rinetd.pl.conf';
my $logger_args = "-t $0";
my $debug = 0;

$main::VERSION = '1.0';

use strict;
use IO::Event;
use Net::Netmask;
use Getopt::Long;
use File::Slurp;
use File::Flock;
require POSIX;

my %config;
my %filters;
my $counter = 1;
sub error;

my $foreground = 0;

Getopt::Long::Configure("auto_version");
GetOptions(
	'configfile=s'	=> \$configfile,
	'foreground!'	=> \$foreground,
) or usage();

usage() if @ARGV != 1;

my $do = shift(@ARGV);

if ($do eq 'help') {
	usage();
} elsif ($do eq 'version') {
	print "$0 - version $main::VERSION\n";
	exit;
} 

my $pidfile;
{
	my $x = $configfile;
	$x =~ s!/!.!g;
	$pidfile = "$pidbase$x.pid";
}

my %newconfig = preconfig();

print "Configuration looks okay\n" if $do eq 'check';

my $killed = 0;
my $locked = 0;
if (-e $pidfile) {
	if ($locked = lock($pidfile, undef, 'nonblocking')) {
		# old process is dead
	} else {
		sleep(2) if -M $pidfile < 2/86400;
		my $oldpid = read_file($pidfile);
		chomp($oldpid);
		if ($oldpid) {
			if ($do eq 'stop' or $do eq 'restart') {
				kill(2,$oldpid) and print "Killed $oldpid\n";
				exit if $do eq 'stop';
				$locked = lock($pidfile);
				$killed = 1;
			} elsif ($do eq 'reload') {
				if (kill(1,$oldpid)) {
					print "Requested reconfiguration\n";
					exit;
				} else {
					print "Kill failed: $!\n";
				}
			} elsif ($do eq 'check') {
				if (kill(0,$oldpid)) {
					print "$0 running - pid $oldpid\n";
					exit;
				} 
			} else {
				error "Exiting $0 processing running, use stop, restart, or reload\n";
			}
		} else {
			error "Pid file $pidfile is invalid but locked, exiting\n";
		}
	}
} else {
	$locked = lock($pidfile, undef, 'nonblocking') 
		or die "Could not lock pid file $pidfile: $!";
}

if ($do eq 'reload' || $do eq 'stop' || $do eq 'check' || ($do eq 'restart' && ! $killed)) {
	print "No $0 running\n";
}

exit if $do eq 'stop';
exit if $do eq 'check';


usage() unless $do eq 'reload' || $do eq 'restart' || $do eq 'start';

unless ($foreground) {
	print "Starting $0 server\n";
	my $pid;
	exit if $pid = fork;
	die "Could not fork: $!" unless defined $pid;
	exit if $pid = fork;
	die "Could not fork: $!" unless defined $pid;

	POSIX::setsid();

	$locked = 0; # why?

	open(STDERR, "|logger $logger_args");
} else {
	print "Starting...\n";
}

$locked or lock($pidfile, undef, 'nonblocking') 
	or die "Could not lock pid file $pidfile: $!";

write_file($pidfile, "$$\n");

select(STDERR);
$| = 1;

postconfig(%newconfig);

my $reload_event = Event->signal(
	signal	=> 'HUP',
	desc	=> 'reload on SIGHUP',
	prio	=> 6,
	cb	=> sub {
		print STDERR "Reconfiguration requested\n";
		postconfig(preconfig());
	},
);
my $quit_event = Event->signal(
	signal	=> 'INT',
	cb	=> sub { 
		print STDERR "Quitting...\n";
		Event::unloop_all();
	},
);

Event::loop();

unlink($pidfile);

exit(0);

sub error
{
	my $e = shift;
	if ($do && $do eq 'stop') {
		warn $e;
	} else {
		die $e;
	}
}
		
sub usage
{
	print <<END;
Usage: $0 [ -c file ] [ -f ] { start | stop | reload | restart | help | version  | check }
 -c		specify config file (defaults to /etc/rinetd.pl.conf)
 -f		run in the foreground (don't detach)
 start		Starts a new rinetd.pl if there isn't one running already
 stop		Stops a running rinetd.pl
 reload		Causes a running rinetd.pl to reload it's config file.  Starts
		a new one if none is running.
 restart	Stops a running rinetd.pl if one is running.  Starts a new one
		irregardless.
 check		Check the configuration file and report the daemon state
END
	exit;
}

sub preconfig
{
	open(CONFIG, $configfile) 
		or error "open $configfile: $!\n";
	my %new;
	$filters{global} = {};
	my $last = 'global';
	while (<CONFIG>) {
		next if /^#/;
		next if /^$/;
		if (/^\s*(allow|deny)\s+(\S+)\s*(?:#.*)?$/) {
			my ($action, $text) = ($1, $2);
			$text =~ s/^(\d+(?:\.\d+)*)(?:\.\*)+$/$1/;
			my $block = new2 Net::Netmask ($text);
			if ($block) {
				$block->{line} = $.;
				$block->{action} = $action;
				$block->storeNetblock($filters{$last});
			} else {
				error "parse error $configfile, line $.: $Net::Netmask::error\n";
			}
			next;
		}
		/^(\S+)\s+(\w+)\s+(\S+)\s+(\w+)\s*(?:#.*)?$/
			or error "Parse error $configfile, line $.: $_";
		my ($fhost, $fport, $thost, $tport) = ($1, $2, $3, $4);
		my $new = join("\n", $fhost, $fport, $thost, $tport, $.);
		$new{$new} = undef;
		$last = $new;
		$filters{$new} = {};
	}
	close(CONFIG);
	return %new;
}

sub postconfig
{
	my (%new) = @_;
	for my $old (keys %config) {
		next if $new{$old};
		$config{$old}->shutdown 
			if $config{$old};
		delete $config{$old};
	}
	for my $new (keys %new) {
		next if $config{$new};
		$config{$new} = new RelayListener (split(/\n/, $new), $filters{$new});
	}
}

package RelayListener;

use strict;
use Net::Netmask;

sub new 
{
	my ($pkg, $fhost, $fport, $thost, $tport, $line, $filter) = @_;
	die unless $fhost;
	die unless $fport;
	die unless $thost;
	die unless $thost;

	my $self = bless {
		tohost	=> $thost,
		toport	=> $tport,
		counter	=> $counter++,
		filter	=> $filter,
		line	=> $line,
		desc	=> "Listen $fhost:$fport -> $thost:$tport",
	}, $pkg;
	$counter++;

	my $listener = IO::Event::Socket::INET->new(
		Listen		=> 20,
		Proto		=> 'tcp',
		LocalPort	=> $fport,
		LocalHost	=> $fhost,
		Description	=> "$fhost:$fport -> $thost:$tport",
		Handler		=> $self,
		Reuse		=> 1,
	);
	unless ($listener) {
		warn "Could not listen at $fhost:$fport: $!";
		return undef;
	}
	print "$self->{desc}\n" if $debug;
	$self->{listener} = $listener;
	return $self;
}

sub shutdown
{
	my ($self) = @_;
	print "SHUTDOWN $self->{desc}\n" if $debug;
	$self->{listener}->close();
	delete $self->{listener};
	$self->{shutdown} = 1;
}

sub ie_connection
{
	my ($self, $ioe) = @_;

	print "CONNECT $self->{desc}\n" if $debug;
	my $client = $ioe->accept();

	my $client_ip = $client->peerhost();

	my $filterblock = findNetblock($client_ip, $self->{filter})
		|| findNetblock($client_ip, $filters{global});

	if ($filterblock && $filterblock->{action} eq 'deny') {
		print "DENIED from $client_ip for $self->{desc}\n";
		$client->print("501 Relay denied $self->{line}\r\n");
		$client->close();
	} else {
		print "accepted from $client_ip for $self->{desc}\n";
		$client->readevents(0);
		RelayConnect->new($client, $self->{desc}, $self->{tohost}, $self->{toport});
	}
}

sub ie_input
{
	die "why?";
}


package RelayConnect;

use strict;
use POSIX qw(ETIMEDOUT);

sub new
{
	my ($pkg, $client, $desc, $tohost, $toport) = @_;

	my $self = bless {
		desc	=> $desc,
		tohost	=> $tohost,
		toport	=> $toport,
		client	=> $client,
		counter	=> $counter++,
	}, $pkg;
		
	IO::Event::Socket::INET->new(
		PeerAddr	=> $tohost,
		PeerPort	=> $toport,
		Proto		=> 'tcp',
		Handler		=> $self,
	);
	return undef;
}

sub ie_connected
{
	my ($self, $ioe) = @_;
	print "CONNECT Server$self->{counter} $self->{desc}\n" if $debug;
	if ($self->{relaylisten}{shutdown}) {
		# oh, well
		$ioe->close();
		return;
	} 
	my $relayclient = Relay->new($self, $self->{client}, 'Client', $self->{desc});
	bless $self, 'Relay';

	$self->{other}		= $relayclient;
	$self->{role}		= 'Server';
	$self->{ioe}		= $ioe;

	delete $self->{client};
	delete $self->{tohost};
	delete $self->{toport};
}

sub ie_connect_failed
{
	my ($self, $ioe, $error) = @_;
	if ($error == ETIMEDOUT) {
		print "TIMEOUT-CONNECT Server$self->{counter} $self->{desc}\n" if $debug;
		$ioe->close();
		new RelayConnect ($self->{client}, $self->{desc}, $self->{tohost}, $self->{toport});
	} else {
		print "NO-CONNECT Server$self->{counter} $self->{desc}: $error\n" if $debug;
		$self->{client}->print("500 Relay open failed\r\n");
		$self->{client}->close();
	}
}

sub ie_input
{
	die "why?";
}


package Relay;

use strict;

# also constructed by re-blessing RelayConnect objects
sub new
{
	my ($pkg, $other, $ioe, $role, $desc) = @_;
	my $self = bless {
		ioe	=> $ioe,
		other	=> $other,
		role	=> $role,
		desc	=> $desc,
		coutner	=> $counter++,
	}, $pkg;
	$ioe->handler($self);
	$ioe->readevents(1);
	return $self;
}

sub close
{
	my ($self) = @_;
	$self->{ioe}->close()
		if $self->{ioe};
	my $o = delete $self->{other};
	$o->close() if $o;
}

sub ie_input
{
	my ($self, $ioe, $ibr) = @_;
	print "DATA $self->{role}$self->{counter} $self->{desc}\n" if $debug;
	if (defined $self->{other}) {
		$self->{other}{ioe}->print($$ibr) || warn "print: $!";
	} else {
		warn "other not defined";
	}
	$$ibr = '';
}

sub ie_werror
{
	my ($self, $ioe) = @_;
	print "WRITE-ERROR $self->{role}$self->{counter} $self->{desc}\n" if $debug;
	$self->close();
}

sub ie_eof
{
	my ($self, $ioe, $ibr) = @_;
	print "EOF $self->{role}$self->{counter} $self->{desc}\n" if $debug;
	$self->close();
}

sub ie_outputoverflow
{
	my ($self, $ioe, $overflowing) = @_;
	print "OVERFLOW-$overflowing $self->{role}$self->{counter} $self->{desc}\n" if $debug;
	$self->{other}{ioe}->readevents(! $overflowing)
		if $self->{other};
}

__END__

=head1 NAME

rinetd.pl - tcp redirection server

=head1 SYNOPSIS

rinetd.pl [ -c configfile ] [ -f ] { start | stop | reload | restart | check }

=head1 DESCRIPTION

Rinetd.pl forwards tcp connections from one IP address and port to
another.  rinetd.pl can forward from multiple ports simultaneously
as defined in a config file (/etc/rinetd.pl.conf).

Rinetd.pl is called "rinetd.pl" instead of simply "rinetd" so as
to not be confused with Thomas Boutell's "rinetd" program.

Exactly one of imperitive is required on the command line:

=over 9

=item start

Start a new rinetd server if there isn't one already running.

=item stop

Stop a running rinetd server

=item restart

Stop the running rinetd server (if one is running).
Start a new rinetd server.

=item reload

Reconfigure the running rinetd server.  Start a new server
if none is running.

=back

The command line options are:

=over 9

=item -c file

Specify an alternative configuration file.  Multiple rinetd.pl servers
can run simultaneously if they have different config files.

=item -f

Run in the foreground.  Normally rinetd.pl detaches itself and runs
as a deamon.  When it runs as a daemon it redirects its output through
the logger(1) program.

=back

=head1 FORWARDING RULES

The format for forwarding rules (in the config file) is:

 from-ip-address from-port to-ip-address to-port

IP addresses and ports can be numeric or named.  Use 0.0.0.0 for
listening on all IP addresses.

=head1 FILTER RULES

Allow and deny rules can control what IP addresses are allowed
to use the server.

The format of rules is:

 allow|deny netblock

Filters that follow a forwarding rule apply to that 
forwarding rule only.

Filters that preceed any forwarding rules apply to 
all forwarding rules if no per-forwarding rule filter
matches.

Filters are not ordered: the most specific filter (smallest
network block) that matches is the one that is used.

Filter rules may be indented for clarity.  Filter rules must be
numeric -- hostnames are not allowed.

=head1 EXAMPLE CONFIG

 # We have to start with the global access 
 # control list.
 # The order of the rules does not matter.

 deny	any 		# '0.0.0.0/0' and 'default' work too
 deny	216.240.32.1 
 allow	216.240.32/24

 0.0.0.0 8282 idiom.com 23

 allow	216.240.47/24
 deny	216.240.47.38
 deny	216.240.32.4

 0.0.0.0 daytime idiom.com daytime # idiom's clock is better
 
=head1 LICENSE

Copyright (C) 2005 David Muir Sharnoff <muir@idiom.com>.
This module may be used/copied/etc on the same terms as Perl 
itself.
