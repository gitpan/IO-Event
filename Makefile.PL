
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile being created.
WriteMakefile(
	'NAME' => 'IO::Event',
	'DISTNAME' => 'IO-Event',
	'VERSION_FROM' => 'Event.pm',
	($] >= 5.005 ?
	    ('ABSTRACT' => 'Tied Filehandles for Nonblocking IO with Object Callbacks',
	     'AUTHOR'	=> 'David Muir Sharnoff <muir@idiom.com>') : ()),
	'dist'   => {COMPRESS=>'gzip', SUFFIX=>'gz'},
	'PREREQ_PM' => {
		'Event' => 0.87,
	 },

);

package MY;

sub postamble {
    <<"END_OF_POSTAMBLE";

pm_to_blib: README

README: Event.pod
\tpod2text Event.pod >README

END_OF_POSTAMBLE
}
