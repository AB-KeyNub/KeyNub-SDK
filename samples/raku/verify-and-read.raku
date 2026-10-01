use v6.d;
# KeyNub SDK - Raku sample: verify a dongle and read what it holds.
#
#     raku samples/raku/verify-and-read.raku      (from the repository root)
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
# In your own project, after `zef install KeyNub::LicDongle`, drop the `use lib` line.
use lib $?FILE.IO.parent.parent.parent.add('bindings').add('raku').add('lib').absolute;
use KeyNub::LicDongle;

my constant LD = KeyNub::LicDongle;

sub report($d) {
    my $i = $d.info;
    say "Protocol v{$i.protocol-major}.{$i.protocol-minor}, firmware "
        ~ "v{$i.firmware-major}.{$i.firmware-minor}.{$i.firmware-patch}, "
        ~ "{$i.data-free} of {$i.data-capacity} bytes free.";
    # The only trace a firmware hang leaves behind. Worth reporting to support.
    say "WARNING: this dongle's previous boot ended in a watchdog reset." if $i.watchdog-reboot;
    my $g = $d.verify-genuine;
    say "Genuine: yes (serial {$g.serial}, provisioned {$g.provisioned-date})";
}

sub read-records($d) {
    my @recs = $d.records;
    say "{@recs.elems} record(s) on the dongle:";
    say sprintf('  %-16s %d bytes', .name, .size) for @recs;
    # A missing record is a normal state, not an error.
    if @recs.first(*.name eq 'license') {
        say "Read {$d.read-record('license').elems} bytes from the license record.";
    }
}

# The part that protects something. At licence-issue time you would
# call app-encrypt once, with a developer dongle, and ship only the sealed data;
# the program then cannot proceed without a dongle, because it holds no other
# copy. Scope::Developer lets any dongle you have issued decrypt it, so one file
# serves every customer; Scope::Device locks it to one dongle.
sub protect-something($d) {
    my $needed = 'the data this program cannot run without'.encode('utf8');
    my $sealed = $d.app-encrypt(LD::Scope::Developer, $needed);
    my $recovered = $d.app-decrypt($sealed);
    my $intact = $recovered.list eqv $needed.list;
    say "App-crypto round trip: {$needed.elems} bytes -> {$sealed.elems} sealed -> "
        ~ ($intact ?? 'recovered intact' !! 'MISMATCH');
}

{
    my $v = LD::library-version();
    say "KeyNub library v$v";
    unless LD::devices() {
        say 'Connect a KeyNub dongle and re-run.';
        exit 0;
    }
    LD::open(-> $d {            # first dongle, or LD::open('serial', -> $d { ... })
        report($d);
        $d.session({            # closed on every exit path
            read-records($d);
            protect-something($d);
        });
    });
    CATCH {
        when X::KeyNub::LicDongle | X::KeyNub::LicDongle::Library {
            say "KeyNub error: {.message}";
            exit 1;
        }
    }
}
