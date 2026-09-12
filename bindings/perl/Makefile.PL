# CPAN manifest.
#
# Uploading is a PAUSE account and a tarball; there is no registry API. PAUSE
# indexes by package name from the .pm, so KeyNub::LicDongle has to be claimed
# before the first upload -- and, as everywhere else here, a version cannot be
# reused once it has been indexed.
#
# VERSION_FROM reads lib/KeyNub/LicDongle.pm rather than repeating the number,
# so the module and the distribution cannot disagree. They already had: the
# module said 1.0.0 while the SDK was at 1.1.0.
#
# Apache-2.0 alone is correct: the distribution contains only Perl source. The
# native library is loaded at run time through the flat companion API and is not
# bundled; its terms are in BINARY-LICENSE.txt.

use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'KeyNub::LicDongle',
    AUTHOR           => 'KeyNub <support@keynub.com>',
    VERSION_FROM     => 'lib/KeyNub/LicDongle.pm',
    ABSTRACT         => 'Perl binding for the KeyNub USB-C license dongle',
    LICENSE          => 'apache_2_0',
    MIN_PERL_VERSION => '5.016',

    PREREQ_PM => {
        # Core since 5.8; named so a minimal perl reports it at install time
        # rather than at the first call.
        'FFI::Platypus' => '1.00',
    },
    TEST_REQUIRES => {
        'Test::More' => '0.98',
    },

    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources   => {
            homepage   => 'https://www.keynub.com/developers/perl/',
            repository => {
                type => 'git',
                url  => 'https://github.com/AB-KeyNub/KeyNub-SDK.git',
                web  => 'https://github.com/AB-KeyNub/KeyNub-SDK',
            },
            bugtracker => {
                web => 'https://github.com/AB-KeyNub/KeyNub-SDK/issues',
            },
        },
    },

    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
    clean => { FILES => 'KeyNub-LicDongle-*' },
);
