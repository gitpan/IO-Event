
package IO::Event;

use Event;
use Event::Watcher qw(R W E T);
use Symbol;
use Carp;
require IO::Handle;
use POSIX qw(BUFSIZ EAGAIN EBADF EINVAL);
use UNIVERSAL qw(isa);
use Socket;

$VERSION = 0.507;

use strict;
use warnings;
my $debug = 0;
my $edebug = 0;

my %fh_table;
my %rxcache;

my @pending_callbacks;
our $in_callback = 0;

sub new
{
	my ($pkg, $fh, $handler, $options) = @_;

	# stolen from IO::Handle
	my $self = bless gensym(), $pkg;

	$handler = (caller)[0]
		unless $handler;

	confess unless ref $fh;

	unless (ref $options) {
		$options = {
			description => $options,
		};
	}

	# stolen from IO::Socket
	${*$self}{ie_fh} = $fh;
	${*$self}{ie_handler} = $handler;
	${*$self}{ie_ibuf} = '';
	${*$self}{ie_obuf} = '';
	${*$self}{ie_obufsize} = BUFSIZ*4;
	${*$self}{ie_autoread} = 1;
	${*$self}{ie_pending} = {};
	${*$self}{ie_desc} = $options->{description} || "wrapper for $fh";
	${*$self}{ie_writeclosed} = EINVAL if $options->{read_only};
	${*$self}{ie_readclosed} = EINVAL if $options->{write_only};

	$self->ie_register();
	$fh->blocking(0);
	print "New IO::Event: ${*$self}{ie_desc} - now nonblocking\n" if $debug;
	
	# stolen from IO::Multiplex
	tie(*$self, $pkg, $self);
	return $self;
}

sub reset
{
	my $self = shift;
	delete ${*$self}{ie_writeclosed};
	delete ${*$self}{ie_readclosed};
	delete ${*$self}{ie_eofinvoked};
	delete ${*$self}{ie_overflowinvoked};
}

# mark as listener
sub listener
{
	my ($self, $listener) = @_;
	$listener = 1 unless defined $listener;
	my $o = ${*$self}{ie_listener};
	${*$self}{ie_listener} = $listener;
	return $o;
}

# call out
sub ie_invoke
{
	my ($self, $required, $method, @args) = @_;

	if ($in_callback && ! ${*$self}->{ie_reentrant}) {
		# we'll do this later
		push(@pending_callbacks, [ $self, $required, $method, @args ])
			unless exists ${*$self}{ie_pending}{$method};
		${*$self}{ie_pending}{$method} = 1;
		return 1;
	}

	local($in_callback) = 1;

	print STDERR "invoking ${*$self}{ie_fileno} ${*$self}{ie_handler}->$method\n"
		if $debug;

	return 0 if ! $required && ! ${*$self}{ie_handler}->can($method);
	if ($debug) {
		my ($pkg, $line, $func) = caller();
		print "DISPATCHING $method from $func at line $line\n";
	}
	eval {
		${*$self}{ie_handler}->$method($self, @args);
	};

	print STDERR "return from ${*$self}{ie_fileno} ${*$self}{ie_handler}->$method handler: $@\n" if $debug;

	return 1 unless $@;
	if (${*$self}{ie_handler}->can('ie_died')) {
		${*$self}{ie_handler}->ie_died($self, $method, $@);
	} else {
		confess $@;
		exit 1;
	}
	return 0;
}

#
# we use a single event handler so that the AUTOLOAD
# function can try a single $event object when looking for
# methods
#
sub ie_dispatch
{
	my ($self, $ievent) = @_;
	my $fh = ${*$self}{ie_fh};
	my $got = $ievent->got;
#print STDERR "GOT $got\n";
#print STDERR "event: $ievent ie_event: ${*$self}{ie_event}\n";
	my $event = ${*$self}{ie_event};
	{
		if ($got & R) {
	#print "read dispatch\n";
			if (${*$self}{ie_listener}) {
				$self->ie_invoke(1, 'ie_connection');
			} elsif (${*$self}{ie_autoread}) {
				$self->ie_input();
			} else {
				$self->ie_invoke(1, 'ie_read_ready', $fh);
			}
			last if ${*$self}{ie_writeclosed} 
				&& ${*$self}{ie_readclosed};
		}
		if ($got & W) {
			if (${*$self}{ie_connecting}) {
#print STDERR "no W\n";
				$event->poll($event->poll & ~(W));
				delete ${*$self}{ie_connecting};
				delete ${*$self}{ie_connect_timeout};
				$self->ie_invoke(0, 'ie_connected');
			} else {
				my $obuf = \${*$self}{ie_obuf};
				my $rv;
				if (length($$obuf)) {
					$rv = syswrite($fh, $$obuf);
					if (defined $rv) {
						substr($$obuf, 0, $rv) = '';
					} elsif ($! == EAGAIN) {
						# this shouldn't happen, but
						# it's not that big a deal
					} else {
						# the file descriptor is toast
						${*$self}{ie_writeclosed} = $!;
						$self->ie_invoke(0, 'ie_werror', $obuf);
					}
				}
				if (${*$self}{ie_closerequested}) {
					if (! length($$obuf)) {
						$self->ie_deregister();
						${*$self}{ie_fh}->close();
						delete ${*$self}{ie_closerequested};
					}
				} else {
					$self->ie_invoke(0, 'ie_output', $obuf, $rv);
					last if ${*$self}{ie_writeclosed} 
						&& ${*$self}{ie_readclosed};
					if (! length($$obuf)) {
						$event->ie_invoke(0, 'ie_outputdone', $obuf);
						last if ${*$self}{ie_writeclosed} 
							&& ${*$self}{ie_readclosed};
						if (! length($$obuf)) {
							$event->poll($event->poll & ~(W));
						}
					}
					if (length($$obuf) > ${*$self}{ie_obufsize}) {
						${*$self}{ie_overflowinvoked} = 1;
						$self->ie_invoke(0, 'ie_outputoverflow', 1, $obuf);
					} elsif (${*$self}{ie_overflowinvoked}) {
						${*$self}{ie_overflowinvoked} = 0;
						$self->ie_invoke(0, 'ie_outputoverflow', 0, $obuf);
					}
				}
			}
			last if ${*$self}{ie_writeclosed} 
				&& ${*$self}{ie_readclosed};
		}
		if ($got & E) {
			if ($fh->eof) {
				if (length(${*$self}{ie_ibuf})) {
					$self->ie_invoke(0, 'ie_input', \${*$self}{ie_ibuf});
				} 
				$self->ie_invoke(0, 'ie_eof', \${*$self}{ie_ibuf})
					unless ${*$self}{ie_eofinvoked}++;
			} else {
				$self->ie_invoke(0, 'ie_exception');
			}
			last if ${*$self}{ie_writeclosed} 
				&& ${*$self}{ie_readclosed};
		}
		if ($got & T) {
			if (${*$self}{ie_connecting} 
				&& ${*$self}{ie_connect_timeout}
				&& time >= ${*$self}{ie_connect_timeout})
			{
				delete ${*$self}{ie_connect_timeout};
				$self->ie_invoke(0, 'ie_connect_timeout')
					|| $event->ie_invoke(0, 'ie_timer');
			} else {
				$event->ie_invoke(0, 'ie_timer');
			}
		}
		last;
	}
	while (@pending_callbacks) {
		my ($ie, $req, $meth, @args) = @{shift @pending_callbacks};
		delete ${*$self}{ie_pending}{$meth};
		if (defined &$meth) {
			$ie->$meth();
		} else {
			$ie->ie_invoke($req, $meth, @args);
		}
	}
}

# same name as handler since we want to intercept invocations
# when processing pending callbacks.  Why?
sub ie_input
{
	my $self = shift;
	my $ibuf = \${*$self}{ie_ibuf};

	# 
	# We'll loop just to make sure we don't miss an event
	# 
	for (;;) {
		my $ol = length($$ibuf);
		my $rv = ${*$self}{ie_fh}->sysread($$ibuf, BUFSIZ, $ol);

		if ($rv) {
			delete ${*$self}{ie_readclosed};
		} elsif (defined($rv)) {
			# must be 0 and closed!
			${*$self}{ie_readclosed} = 1;
			last;
		} elsif ($! == EAGAIN) {
			# readclosed = 0?
			last;
		} else {
			# errors other than EAGAIN aren't recoverable
			${*$self}{ie_readclosed} = $!;
			last;
		}

		$self->ie_invoke(1, 'ie_input', $ibuf);
	}

	if (${*$self}{ie_readclosed}) {
		$self->ie_invoke(1, 'ie_input', $ibuf)
			if length($$ibuf);
		$self->ie_invoke(0, 'ie_eof', $ibuf)
			unless ${*$self}{ie_eofinvoked}++;
		my $event = ${*$self}{ie_event};
		$event->poll($event->poll & ~R)
			if $event;
	}
}

sub reentrant
{
	my $self = shift;
	my $old = ${*$self}{ie_reentrant};
	if (@_) {
		${*$self}{ie_reentrant} = $_[0];
	}
	return $old;
}
	
sub output_bufsize
{
	my $self = shift;
	my $old = ${*$self}{ie_obufsize};
	if (@_) {
		${*$self}{ie_obufsize} = $_[0];
		if (length(${*$self}{ie_obuf}) > ${*$self}{ie_obufsize}) {
			$self->ie_invoke(0, 'ie_outputoverflow', 1, ${*$self}{ie_obuf});
			${*$self}{ie_overflowinvoked} = 1;
		} elsif (${*$self}{ie_overflowinvoked}) {
			$self->ie_invoke(0, 'ie_outputoverflow', 0, ${*$self}{ie_obuf});
			${*$self}{ie_overflowinvoked} = 0;
		}
		# while this should trigger callbacks, we don't want to assume
		# that our caller's code is re-enterant.
	}
	return $old;
}

# get/set autoread
sub autoread
{
	my $self = shift;
	my $old = ${*$self}{ie_autoread};
	if (@_) {
		${*$self}{ie_autoread} = $_[0];
		if (${*$self}{ie_readclosed}) {
			delete ${*$self}{ie_readclosed};
			my $event = ${*$self}{ie_event};
			$event->poll($event->poll | R);
		}
	}
	return $old;
}

# start watching for write-ready events
sub readevents
{
	my $self = shift;
	my $event = ${*$self}{ie_event};
	my $poll = $event->poll;
	my $old = !! $poll & R;
	if (@_ > 1) {
		$poll = $poll & ~R;
		$poll = $poll | R if $_[0];
		$event->poll($poll);
	}
	return $old;
}

# start watching for write-ready events
sub drain
{
	my ($self) = @_;
	my $event = ${*$self}{ie_event};
	$event->poll($event->poll | W);
}

# register with Event
sub ie_register
{
	my ($self) = @_;
	my $fh = ${*$self}{ie_fh};
	$fh->blocking(0);
	$fh->autoflush(1);
	my $R = ${*$self}{ie_readclosed}
		? 0
		: R;
	${*$self}{ie_event} = Event->io(
		fd	=> (${*$self}{ie_fileno} = $fh->fileno),
		poll	=> E|T|$R,
		cb	=> [ $self, 'ie_dispatch' ],
		desc	=> ${*$self}{ie_desc},
		edebug	=> $edebug,
	);
	print STDERR "registered ${*$self}{ie_fileno}:${*$self}{ie_desc} $self $fh ${*$self}{ie_event}\n"
		if $debug;
}

# deregister with Event
sub ie_deregister
{
	my ($self) = @_;
	my $fh = ${*$self}{ie_fh};
	delete $fh_table{$fh};
	${*$self}{ie_event}->cancel;
	delete ${*$self}{ie_event};
}

# the standard max() function
sub ie_max
{
	my ($max, @stuff) = @_;
	for my $t (@stuff) {
		$max = $t if $t > $max;
	}
	return $max;
}

# get the Filehandle
sub filehandle
{
	my ($self) = @_;
	return ${*$self}{ie_fh};
}

# get the Event
sub event
{
	my ($self) = @_;
	return ${*$self}{ie_event};
}

# set the handler
sub handler
{
	my $self = shift;
	my $old = ${*$self}{ie_handler};
	${*$self}{ie_handler} = $_[0]
		if @_;
	return $old;
}

# is there enough?
sub can_read
{
	my ($self, $length) = @_;
	my $l = length(${*$self}{ie_ibuf});
	return $l if $l && $l >= $length;
	return "0 but true" if $length <= 0;
	return 0;
}

# reads N characters or returns undef if it can't 
sub getsome
{
	my ($self, $length) = @_;
	return undef unless ${*$self}{ie_autoread};
	my $ibuf = \${*$self}{ie_ibuf};
	$length = length($$ibuf)
		unless defined $length;
	my $tmp = substr($$ibuf, 0, $length);
	substr($$ibuf, 0, $length) = '';
	return undef if ! length($tmp) && ! $self->eof2;
	return $tmp;
}

# from base perl
# will this work right for SOCK_DGRAM?
sub connect
{
	my $self = shift;
	my $fh = ${*$self}{ie_fh};
	my $rv = $fh->connect(@_);
	$self->reset;
	my $event = ${*$self}{ie_event};
	$event->poll($event->poll | R);
	unless($fh->connected()) {
		${*$self}{ie_connecting} = 1;
		$event->poll($event->poll | W);
		${*$self}{ie_connect_timeout} = time 
			+ ${*$self}{ie_socket_timeout}
			if ${*$self}{ie_socket_timeout};
	}
	return $rv;
}

# from IO::Socket
sub listen
{
	my $self = shift;
	my $fh = ${*$self}{ie_fh};
	my $rv = $fh->listen();
	$self->listener(1);
	return $rv;
}

# from IO::Socket
sub accept
{
	my ($self, $handler) = @_;
	my $fh = ${*$self}{ie_fh};
	my $newfh = $fh->accept();
	return undef unless $newfh;

	# it appears that sockdomain isn't set on accept()ed sockets
	my $sd = $fh->sockdomain;

	my $desc;
	if ($sd == &AF_INET) {
		$desc = sprintf "Accepted socket from %s:%s to %s:%s",
			$newfh->peerhost, $newfh->peerport,
			$newfh->sockhost, $newfh->sockport;
	} elsif ($sd == &AF_UNIX) {
		$desc = sprintf "Accepted socket from %s to %s",
			$newfh->peerpath, $newfh->hostpath;
	} else {
		$desc = "Accept for ${*$self}{ie_desc}";
	}
	$handler = ${*$self}{ie_handler} 
		unless defined $handler;
	my $new = IO::Event->new($newfh, $handler, $desc);
	${*$new}{ie_obufsize} = ${*$self}{ie_obufsize};
	${*$new}{ie_reentrant} = ${*$self}{ie_reentrant};
	return $new;
}

# sub loop not required as AUTOLOAD will call Event::loop.

# not the same as IO::Handle
sub input_record_separator
{
	my $self = shift;
	my $old = ${*$self}{ie_irs};
	${*$self}{ie_irs} = $_[0]
		if @_;
	if ($debug) {
		my $fn = $self->fileno;
		my $x = ${*$self}{ie_irs};
		$x =~ s/\n/\\n/g;
		print "input_record_separator($fn) = '$x'\n";
	}
	return $old;
}

# from IO::Handle
sub close
{
	my ($self) = @_;
	my $obuf = \${*$self}{ie_obuf};
	if (length($$obuf)) {
		${*$self}{ie_closerequested} = 1;
		${*$self}{ie_writeclosed} = 1;
		${*$self}{ie_readclosed} = 1;
	} else {
		$self->forceclose;
	}
}

sub forceclose
{
	my ($self) = @_;
	$self->ie_deregister();
	${*$self}{ie_fh}->close();
	${*$self}{ie_writeclosed} = 1;
	${*$self}{ie_readclosed} = 1;
	print STDERR "forceclose(${*$self}{ie_desc})\n" if $debug;
}

# from IO::Handle
sub open 
{ 
	my $self = shift;
	my $fh = ${*$self}{ie_fh};
	$self->close()
		if $fh->opened;
	$self->ie_deregister();
	$self->reset;
	my $r;
	if (@_ == 1) {
		$r = CORE::open($fh, $_[0]);
	} elsif (@_ == 2) {
		$r = CORE::open($fh, $_[0], $_[1]);
	} elsif (@_ == 3) {
		$r = CORE::open($fh, $_[0], $_[1], $_[4]);
	} elsif (@_ > 3) {
		$r = CORE::open($fh, $_[0], $_[1], $_[4], @_);
	} else {
		confess("open w/o enoug args");
	}
	return undef unless defined $r;
	$self->ie_register();
	return $r;
}


# from IO::Handle		VAR LENGTH [OFFSET]
#
# this returns nothing unless there is enough to fill
# the request or it's at eof
#
sub sysread 
{
	my $self = shift;

	unless (${*$self}{ie_autoread}) {
		my $buf = shift;
		my $length = shift;
		my $rv = ${*$self}{ie_fh}->sysread($buf, $length, @_);

		if ($rv) {
			delete ${*$self}{ie_readclosed};
		} elsif (defined($rv)) {
			# must be 0 and closed!
			${*$self}{ie_readclosed} = 1;
		} elsif ($! == EAGAIN) {
			# nothing there
		} else {
			# errors other than EAGAIN aren't recoverable
			${*$self}{ie_readclosed} = $!;
		}
		return $rv;
	}

	my $ibuf = \${*$self}{ie_ibuf};
	my $length = length($$ibuf);

	return undef unless $length >= $_[1] || $self->eof2;

	(defined $_[2] ? 
		substr ($_[0], $_[2], length($_[0]))
		: $_[0]) 
			= substr($$ibuf, 0, $_[1]);

	substr($$ibuf, 0, $_[1]) = '';
	return ($length-length($$ibuf));
}

# from IO::Handle
sub syswrite
{
	my ($self, $data, $length, $offset) = @_;
	if (defined $offset or defined $length) {
		return $self->print(substr($data, $offset, $length));
	} else {
		return $self->print($data);
	}
}

# like Data::LineBuffer
sub get
{
	my $self = shift;
	return undef unless ${*$self}{ie_autoread};
	my $ibuf = \${*$self}{ie_ibuf};
	my $irs = "\n";
	my $index = index($$ibuf, $irs);
	if ($index < 0) {
		return undef unless $self->eof2;
		my $l = $$ibuf;
		$$ibuf = '';
		return undef unless length($l);
		return $l;
	}
	my $line = substr($$ibuf, 0, $index - length($irs) + 1);
	substr($$ibuf, 0, $index + 1) = '';
	return $line;
}

# like Data::LineBuffer
# input_record_separator is always "\n".
sub unget
{
	my $self = shift;
	my $irs = "\n";
	no warnings;
	substr(${*$self}{ie_ibuf}, 0, 0) 
		= join($irs, @_, undef);
}

# from IO::Handle
sub getline 
{ 
	my $self = shift;
	return undef unless ${*$self}{ie_autoread};
	my $ibuf = \${*$self}{ie_ibuf};
	my $fh = ${*$self}{ie_fh};
	my $irs = exists ${*$self}{ie_irs} ? ${*$self}{ie_irs} : $/;
	my $line;


	# perl's handling if input record separators is 
	# not completely simple.  
	$irs = $$irs if ref $irs;
	my $index;
	if ($irs =~ /^\d/ && int($irs)) {
		if ($irs > 0 && length($$ibuf) >= $irs) {
			$line = substr($$ibuf, 0, $irs);
		} elsif ($self->eof2) {
			$line = $$ibuf;
		} 
	} elsif (! defined $irs) {
		if ($self->eof2) {
			$line = $$ibuf;
		} 
	} elsif ($irs eq '') {
		# paragraph mode
		$$ibuf =~ s/^\n+//;
		$irs = "\n\n";
		$index = index($$ibuf, "\n\n");
	} else {
		# multi-character (or just \n)
		$index = index($$ibuf, $irs);
	}
	if (defined $index) {
		$line = $index > -1
			? substr($$ibuf, 0, $index+length($irs))
			: ($self->eof2 ? $$ibuf : undef);
	}
	if ($debug) {
		no warnings;
		my $x = $$ibuf;
		substr($x, 0, length($line)) = '';
		$x =~ s/\n/\\n/g;
		my $y = $irs;
		$y =~ s/\n/\\n/g;
		print "looked for '$y', returning undef, keeping '$x'\n" unless defined $line;
		my $z = $line;
		$z =~ s/\n/\\n/g;
		print "looked for '$y', returning '$z', keeping '$x'\n" if defined $line;
	}
	return undef unless defined($line) && length($line);
	substr($$ibuf, 0, length($line)) = '';
	return $line;
}

# is the following a good idea?
#sub tell
#{
#	my ($self) = @_;
#	return ${*$self}{ie_fh}->tell() + length(${*$self}{ie_obuf});
#}

# from IO::Handle
sub getlines
{
	my $self = shift;
	return undef unless ${*$self}{ie_autoread};
	my $ibuf = \${*$self}{ie_ibuf};
	#my $ol = length($$ibuf);
	my $irs = exists ${*$self}{ie_irs} ? ${*$self}{ie_irs} : $/;
	my @lines;
	if ($debug) {
		my $x = $irs;
		$x =~ s/\n/\\n/g;
		my $fn = $self->fileno;
		print "getlines($fn, '$x')\n";
	}
	if ($irs =~ /^\d/ && int($irs)) {
		if ($irs > 0) {
			@lines = unpack("(a$irs)*", $$ibuf);
			$$ibuf = '';
			$$ibuf = pop(@lines)
				if length($lines[$#lines]) != $irs && ! $self->eof2;
		} else {
			return undef unless $self->eof2;
			@lines = $$ibuf;
			$$ibuf = '';
		}
	} elsif (! defined $irs) {
		return undef unless $self->eof2;
		@lines = $$ibuf;
		$$ibuf = '';
	} elsif ($irs eq '') {
		# paragraphish mode.
		$$ibuf =~ s/^\n+//;
		@lines = grep($_ ne '', split(/(.*?\n\n)\n*/s, $$ibuf));
		$$ibuf = '';
		$$ibuf = pop(@lines)
			if @lines && substr($lines[$#lines], -2) ne "\n\n" && ! $self->eof2;
		if ($debug) {
			my $x = join('|', @lines);
			$x =~ s/\n/\\n/g;
			my $y = $$ibuf;
			$y =~ s/\n/\\n/g;
			print "getlines returns '$x' but holds onto '$y'\n";
		}
	} else {
		# multicharacter
		#$rxcache{$irs} = qr/(?<=\Q$irs\E)/
		$rxcache{$irs} = qr/(.*?\Q$irs\E)/s
			unless exists $rxcache{$irs};
		my $irsrx = $rxcache{$irs};
		@lines = grep($_ ne '', split(/$rxcache{$irs}/, $$ibuf));
		return undef
			unless @lines;
		$$ibuf = '';
		$$ibuf = pop(@lines)
			if substr($lines[$#lines], 0-length($irs)) ne $irs && ! $self->eof2;
	}
	return @lines;
}

# from IO::Handle
sub ungetc
{
	my ($self, $ord) = @_;
	my $ibuf = \${*$self}{ie_ibuf};
	substr($$ibuf, 0, 0) = chr($ord);
}

# from FileHandle::Unget & original
sub ungets
{
	my $self = shift;
	substr(${*$self}{ie_ibuf}, 0, 0) 
		= join('', @_);
}

*xungetc = \&ungets;
*ungetline = \&ungets;

# from IO::Handle
sub getc
{
	my ($self) = @_;
	$self->getsome(1);
}

# from IO::Handle
sub print
{
	my ($self, @data) = @_;
	$! = ${*$self}{ie_writeclosed} && return undef 	
		if ${*$self}{ie_writeclosed};
	my $ol;
	my $rv;
	my $er;
	my $obuf = \${*$self}{ie_obuf};
	if ($ol = length($$obuf)) {
		$$obuf .= join('', @data);
		$rv = length($$obuf) - $ol;
	} else {
		my $fh = ${*$self}{ie_fh};
		my $data = join('', @data);
		$rv = CORE::syswrite($fh, $data);
		if (defined($rv) && $rv < length($data)) {
			$$obuf = substr($data, $rv, length($data)-$rv);
			$self->ie_drain;
		} else {
			$er = 0+$!;
		}
	}
	if (length($$obuf) > ${*$self}{ie_obufsize}) {
		$self->ie_invoke(0, 'ie_outputoverflow', 1, $obuf);
		${*$self}{ie_overflowinvoked} = 1;
	} elsif (${*$self}{ie_overflowinvoked}) {
		$self->ie_invoke(0, 'ie_outputoverflow', 0, $obuf);
		${*$self}{ie_overflowinvoked} = 0;
	}
	$! = $er;
	return $rv;
}

# from IO::Handle
sub eof
{
	my ($self) = @_;
	return 0 if length(${*$self}{ie_ibuf});
	return 1 if ${*$self}{ie_readclosed};
	return 0;
	# return ${*$self}{ie_fh}->eof;
}

# internal use only.
# just like eof, but we assume the input buffer is empty
sub eof2
{
	my ($self) = @_;
	if ($debug) {
		my $fn = $self->fileno;
		print "eof2($fn)...";
		print " readclosed" if ${*$self}{ie_readclosed};
		#print " EOF" if ${*$self}{ie_fh}->eof;
		my $x = 0;
		$x = 1 if ${*$self}{ie_readclosed};
		# $x = ${*$self}{ie_fh}->eof unless defined $x;
		print " =$x\n";
	}
	return 1 if ${*$self}{ie_readclosed};
	return 0;
	# return ${*$self}{ie_fh}->eof;
}

sub fileno
{
	my $self = shift;
	return ${*$self}{ie_fileno}
		if defined ${*$self}{ie_fileno};
	return ${*$self}{ie_fh}->fileno();
}

sub DESTROY
{
	my $self = shift;
	my $no = $self->fileno;
	print "DESTROY $no...\n" if $debug;
	${*$self}{ie_event}->cancel
		if ${*$self}{ie_event};
}

sub AUTOLOAD
{
	my $self = shift;
	our $AUTOLOAD;
	my $a = $AUTOLOAD;
	$a =~ s/.*:://;
	
	# for whatever reason, UNIVERSAL::can() 
	# doesn't seem to work on some filehandles

	my $r;
	my @r;
	my $fh = ${*$self}{ie_fh};
	if ($fh) {
		if (wantarray) {
			eval { @r = $fh->$a(@_) };
		} else {
			eval { $r = $fh->$a(@_) };
		}
		if ($@ && $@ =~ /Can't locate object method "(.*?)" via package/) {
			my $event = ${*$self}{ie_event};
			if ($1 ne $a) {
				# nothing to do
			} elsif ($event->can($a)) {
				if (wantarray) {
					eval { @r = $event->$a(@_) };
				} else {
					eval { $r = $event->$a(@_) };
				}
			} else {
				confess qq{Can't locate object method "$a" via "@{[ ref($self) ]}", "@{[ ref($fh)||'IO::Handle' ]}", or "@{[ ref($event) ]}"};
			}
		}
	} else {
		my $event = ${*$self}{ie_event};
		if ($event->can($a)) {
			if (wantarray) {
				eval { @r = $event->$a(@_) };
			} else {
				eval { $r = $event->$a(@_) };
			}
		} else {
			confess qq{Can't locate object method "$a" via "@{[ ref($self) ]}" or "@{[ ref($event) ]}"};
		}
	}
	confess $@ if $@;
	return @r if wantarray;
	return $r;
}

sub TIEHANDLE
{
	my ($pkg, $self) = @_;
	return $self;
}

sub PRINTF
{
	my $self = shift;
	$self->print(sprintf(shift, @_));
}

sub READLINE 
{
	my $self = shift;
	wantarray ? $self->getlines : $self->getline;
}

no warnings;

*PRINT = \&print;

*READ = \&sysread;

# from IO::Handle
*read = \&sysread;

*WRITE = \&syswrite;

*CLOSE = \&close;

*EOF = \&eof;

*TELL = \&tell;

*FILENO = \&fileno;

*SEEK = \&seek;

*BINMODE = \&binmode;

*OPEN = \&open;

*GETC = \&getc;

use warnings;

package IO::Event::Socket::INET;

# XXX version 1.26 required for IO::Socket::INET

our(@ISA) = qw(IO::Event);
use Event::Watcher qw(R W E T);

sub new
{
	my ($pkg, $a, $b, %sock) = @_;

	# emulate behavior in the IO::Socket::INET API
	if (! %sock && ! $b) {
		$sock{PeerAddr} = $a;
	} else {
		$sock{$a} = $b;
	}

	my $handler = $sock{Handler} || (caller)[0];
	delete $sock{Handler};

	my $timeout;
	if ($sock{Timeout}) {
		$timeout = $sock{Timeout};
		delete $sock{Timeout};
	}

	$sock{Blocking} = 0;

	my (%ds) = %sock;

	delete $sock{Description};

	require IO::Socket::INET;
	my $fh = new IO::Socket::INET(%sock);
	return undef unless defined $fh;

	if (grep(/Peer/, keys %sock)) {
		$ds{LocalPort} = $fh->sockport
			unless defined $ds{LocalPort};
		$ds{LocalHost} = $fh->sockhost
			unless defined $ds{LocalHost};
	}

	my $desc = $ds{Description} 
		|| join(" ", map { "$_=$ds{$_}" } sort keys %ds);

	return undef unless $fh;
	my $self = $pkg->SUPER::new($fh, $handler, $desc);
	bless $self, $pkg;
	$self->listener(1)
		if $sock{Listen};
	$fh->blocking(0); # may be redundant
	if (grep(/Peer/, keys %sock)) {
		if ($fh->connected()) {
			$self->ie_invoke(0, 'ie_connected');
		} else {
			${*$self}{ie_connecting} = 1;
			my $event = ${*$self}{ie_event};
			$event->poll($event->poll | W);
			${*$self}{ie_connect_timeout} = $timeout + time
				if $timeout;
		}
	}
	${*$self}{ie_socket_timeout} = $timeout
		if $timeout;

	return $self;
}

package IO::Event::Socket::UNIX;

our(@ISA) = qw(IO::Event);

use Event::Watcher qw(R W E T);

sub new
{
	my ($pkg, $a, $b, %sock) = @_;

	# emulate behavior in the IO::Socket::INET API
	if (! %sock && ! $b) {
		$sock{Peer} = $a;
	} else {
		$sock{$a} = $b;
	}

	my $handler = $sock{Handler} || (caller)[0];
	delete $sock{Handler};

	my $desc = $sock{Description} 
		|| join(" ", map { "$_=$sock{$_}" } sort keys %sock);
	delete $sock{Description};

	require IO::Socket::UNIX;
	my $fh = new IO::Socket::UNIX(%sock);

	return undef unless $fh;
	my $self = $pkg->SUPER::new($fh, $handler, $desc);
	bless $self, $pkg;
	$self->listener(1)
		if $sock{Listen};
	$fh->blocking(0); 
	if ($sock{Peer}) {
		if ($fh->connected()) {
			$self->ie_invoke(0, 'ie_connected');
		} else {
			${*$self}{ie_connecting} = 1;
			my $event = ${*$self}{ie_event};
			$event->poll($event->poll | W);
		}
	}

	return $self;
}

1;

