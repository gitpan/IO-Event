
package IO::Event;

use Event;
use Event::Watcher qw(R W E T);
use Symbol;
use Carp;
require IO::Handle;
use POSIX qw(BUFSIZ);
use UNIVERSAL qw(isa);
use Socket;

$VERSION = 0.3;

use strict;
use diagnostics;

my %fh_table;
my $debug = 0;
my %rxcache;

sub new
{
	my ($pkg, $fh, $handler, $description) = @_;

	# stolen from IO::Handle
	my $self = bless gensym(), $pkg;

	$handler = (caller)[0]
		unless $handler;

	confess unless ref $fh;

	# stolen from IO::Socket
	${*$self}{ie_fh} = $fh;
	${*$self}{ie_handler} = $handler;
	${*$self}{ie_ibuf} = '';
#	${*$self}{ie_amount_read} = 0;
	${*$self}{ie_iwatermark} = BUFSIZ*4;
	${*$self}{ie_obuf} = '';
	${*$self}{ie_owatermark} = BUFSIZ*4;
	${*$self}{ie_autoread} = 1;
	${*$self}{ie_desc} = $description || "wrapper for $fh";

	$self->ie_register();

	# stolen from IO::Multiplex
	tie(*$self, $pkg, $self);
	return $self;
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
	print STDERR "invoking ${*$self}{ie_fileno} ${*$self}{ie_handler}->$method\n"
		if $debug;
		
	return 0 if ! $required && ! ${*$self}{ie_handler}->can($method);
	eval {
		${*$self}{ie_handler}->$method($self, @args);
	};
	return 1 unless $@;
	if (${*$self}{ie_handler}->can('ie_died')) {
		eval {
			${*$self}{ie_handler}->ie_died($self, $method, $@);
		};
	} else {
		confess $@;
	}
	return 0;
}

#
# we use a single event handler so that the AUTOLOAD
# function can try a sinle $event object when looking for
# methods
#
sub ie_dispatch
{
	my ($self, $event) = @_;
	my $fh = ${*$self}{ie_fh};
	my $handler = ${*$self}{ie_handler};
	my $got = $event->got;
	if ($got & R) {
		if (${*$self}{ie_listener}) {
			$self->ie_invoke(1, 'ie_connection');
		} elsif (${*$self}{ie_autoread}) {
			my $ibuf = \${*$self}{ie_ibuf};
			#my $opos = pos($$ibuf);
			my $ol = length($$ibuf);

			my $rv = sysread($fh, $$ibuf, POSIX::BUFSIZ);
#			${*$self}{ie_amount_read} += $rv
#				if defined $rv;
			
#my $x = $$ibuf;
#$x =~ s/\n/\\n/g;
#print "sysread of ${*$self}{ie_fileno} got $rv bytes: '$x'\n";
			$self->ie_invoke(1, 'ie_input', $ibuf);

			if ($rv == 0 && $fh->eof) {
				$self->ie_invoke(0, 'ie_eof', $ibuf);
			} else {
				my $wm = ${*$self}{ie_iwatermark};
				$handler->ie_rhighwater($self, $ibuf)
					if $ol < $wm && length($$ibuf) >= $wm;

				$handler->ie_rlowwater($self, $ibuf)
					if $ol >= $wm && length($$ibuf) < $wm;
			}
		} else {
			$self->ie_invoke(1, 'ie_read_ready', $fh);
		}
	}
	if ($got & W) {
		if (${*$self}{ie_connecting}) {
			delete ${*$self}{ie_connecting};
			delete ${*$self}{ie_connect_timeout};
			$self->ie_invoke(0, 'ie_connected');
			$event->poll($event->poll & ~(W));
		} else {
			my $obuf = \${*$self}{ie_obuf};
			my $rv;
			if (length($$obuf)) {
				$rv = syswrite($fh, $$obuf);
				if (defined $rv) {
					substr($$obuf, 0, $rv) = '';
				} else {
					# XXX die instead?
					warn "write to $fh: $rv\n";
				}
			}
			$self->ie_invoke(0, 'ie_output', $obuf, $rv);
			if (! length($$obuf)) {
				$event->ie_invoke(0, 'ie_outputdone', $obuf);
				if (! length($$obuf)) {
					$event->poll($event->poll & ~(W));
				}
			}
		}
	}
	if ($got & E) {
		$event->ie_invoke(0, 'ie_exception');
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
}

# get/set autoread
sub autoread
{
	my $self = shift;
	my $old = ${*$self}{ie_autoread};
	${*$self}{ie_autoread} = $_[0]
		if @_;
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
	${*$self}{ie_event} = Event->io(
		'fd' => (${*$self}{ie_fileno} = $fh->fileno),
		'poll' => R|E|T,
		'cb' => [ $self, 'ie_dispatch' ],
		'desc' => ${*$self}{ie_desc},
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

# from IO::Socket
sub connect
{
	my $self = shift;
	my $fh = ${*$self}{ie_fh};
	my $rv = $fh->connect(@_);
	unless($fh->connected()) {
		${*$self}{ie_connecting} = 1;
		my $event = ${*$self}{ie_event};
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
	${*$new}{ie_iwatermark} = ${*$self}{ie_iwatermark};
	${*$new}{ie_owatermark} = ${*$self}{ie_owatermark};
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
	return $old;
}

# from IO::Handle
sub close
{
	my ($self) = @_;
	$self->ie_deregister();
	my $fh = ${*$self}{ie_fh};
	$fh->close();
}

# from IO::Handle
sub open
{
	my ($self) = @_;
	my $fh = ${*$self}{ie_fh};
	$fh->open(@_);
}

# from IO::Handle
sub read
{
	my ($self, $length) = @_;
	my $ibuf = \${*$self}{ie_ibuf};
	$length = length($$ibuf)
		unless defined $length;
	my $tmp = substr($$ibuf, 0, $length);
	substr($$ibuf, 0, $length) = '';
	return undef if ! length($tmp) && ! ${*$self}{ie_fh}->eof;
	return $tmp;
}

# from IO::Handle
sub sysread 
{
	my $self = shift;

	my $ibuf = \${*$self}{ie_ibuf};
	my $length = length($$ibuf);

	return undef unless $length >= $_[1]
		|| ${*$self}{ie_fh}->eof;

	(defined $_[2] ? 
		substr ($_[0], $_[2], $_[1]) 
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
	my $ibuf = \${*$self}{ie_ibuf};
	my $fh = ${*$self}{ie_fh};
	my $irs = "\n";
	my $index = index($$ibuf, $irs);
	if ($index < 0) {
		return undef unless $fh->eof;
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
	substr(${*$self}{ie_ibuf}, 0, 0) 
		= join($irs, @_, undef);
}

# from IO::Handle
sub getline 
{ 
	my $self = shift;
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
		} elsif ($fh->eof) {
			$line = $$ibuf;
		} 
	} elsif (! defined $irs) {
		if ($fh->eof) {
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
			: ($fh->eof
				? $$ibuf
				: undef);
	}
	return undef unless length($line);
	substr($$ibuf, 0, length($line)) = '';
	return $line;
}

# is the following a good idea?
#sub tell
#{
#	my ($self) = @_;
#	return ${*$self}{ie_fh}->tell() + length(${*$self}{ie_obuf});
#}

# original
sub ungetline
{
	my $self = shift;
	substr(${*$self}{ie_ibuf}, 0, 0) 
		= join('', @_);
}

# from IO::Handle
sub getlines
{
	my $self = shift;
	my $ibuf = \${*$self}{ie_ibuf};
	#my $ol = length($$ibuf);
	my $fh = ${*$self}{ie_fh};
	my $irs = exists ${*$self}{ie_irs} ? ${*$self}{ie_irs} : $/;
	my @lines;
	if ($irs =~ /^\d/ && int($irs)) {
		if ($irs > 0) {
			@lines = unpack("(a$irs)*", $$ibuf);
			$$ibuf = '';
			$$ibuf = pop(@lines)
				if length($lines[$#lines]) != $irs
					&& ! $fh->eof;
		} else {
			return undef unless $fh->eof;
			@lines = $$ibuf;
			$$ibuf = '';
		}
	} elsif (! defined $irs) {
		return undef unless $fh->eof;
		@lines = $$ibuf;
		$$ibuf = '';
	} elsif ($irs eq '') {
		# paragraphish mode.
		$$ibuf =~ s/^\n+//;
#my $x = $$ibuf;
#$x =~ s/\n/\\n/g;
#print "BEFORE: $x\n";
		@lines = grep($_ ne '', split(/(.*?\n\n)\n*/s, $$ibuf));
#my (@x) = @lines;
#for my $x (@x) {
#$x =~ s/\n/\\n/g;
#}
#print 'AFTER: <',join("><",@x),">\n";
		$$ibuf = '';
		$$ibuf = pop(@lines)
			if substr($lines[$#lines], -2) ne "\n\n"
				&& ! $fh->eof;
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
			if substr($lines[$#lines], 0-length($irs)) ne $irs
				&& ! $fh->eof;
	}
	return @lines;
}

# from IO::Handle
sub ungetc
{
	my ($self, $ord) = @_;
	my $ibuf = \${*$self}{ie_ibuf};
	#my $opos = pos($$ibuf);
	$$ibuf .= chr($ord);
	#pos($$ibuf) = $opos;
}

# from IO::Handle
sub print
{
	my ($self, @data) = @_;
	my $ol;
	if ($ol = length(${*$self}{ie_obuf})) {
		${*$self}{ie_obuf} .= join('', @data);
		${*$self}{ie_handler}->ie_whighwater(1)
			if length(${*$self}{ie_obuf}) >= ${*$self}{ie_owatermark}
				&& $ol < ${*$self}{ie_owatermark}
				&& ${*$self}{ie_handler}->can('ie_whighwater');
		return (length(${*$self}{ie_obuf}) - $ol);
	} else {
		my $fh = ${*$self}{ie_fh};
		my $data = join('', @data);
		my $rv = CORE::syswrite($fh, $data);
		if ($rv < length($data)) {
			${*$self}{ie_obuf} = substr($data, $rv, length($data)-$rv);
			$self->ie_drain;
		}
		return $rv;
	}
}

# from IO::Handle
sub eof
{
	my ($self) = @_;
	return 0 if length(${*$self}{ie_ibuf});
	return ${*$self}{ie_fh}->eof();
}

sub DESTROY
{
	# we need this so we don't try to AUTOLOAD a DESTROY during global destruction
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
	confess $@ if $@;
	return @r if wantarray;
	return $r;
}

sub TIEHANDLE
{
	my ($pkg, $self) = @_;
	return $self;
}

sub PRINT { goto &print; }

sub PRINTF
{
	my $self = shift;
	$self->print(sprintf(shift, @_));
}

sub READLINE 
{
	my $self = shift;
	if (wantarray) {
		return $self->getlines;
	} else {
		return $self->getline;
	}
}

sub GETC
{
	my ($self) = @_;
	$self->read(1);
}

sub READ {
	my $self = shift;
	my $bufref = \$_[0];
	my (undef,$len,$offset) = @_;

	return undef if ! length(${*$self}{ie_ibuf}) && $self->eof;
	$$bufref = '' unless defined $$bufref;
	my $willread = length(${*$self}{ie_ibuf});
	$willread = $len if $willread > $len;
	my $oldlen = length($$bufref);
	$offset = 0 unless defined $offset;
	substr($$bufref, $offset, length($$bufref)) = $self->read($willread);
	return $willread;
}

sub WRITE { goto &syswrite; }

sub CLOSE { goto &close; }

sub EOF { goto &eof; }

sub TELL { goto &tell; }

sub FILENO { goto &fileno; }

sub SEEK { goto &seek; }

sub BINMODE { goto &binmode; }

sub OPEN 
{ 
	my $self = shift;
	my $fh = ${*$self}{ie_fh};
	$self->close()
		if $fh->opened;
	$self->ie_deregister();
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

