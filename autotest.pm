# Copyright © 2009-2013 Bernhard M. Wiedemann
# Copyright © 2012-2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package autotest;
use strict;
use bmwqemu;
use Exporter qw/import/;
our @EXPORT_OK = qw/loadtest $current_test query_isotovideo/;

use File::Basename;
use File::Spec;
use Socket;
use IO::Handle;
use POSIX qw(_exit);
use cv;

our %tests;        # scheduled or run tests
our @testorder;    # for keeping them in order
our $isotovideo;

sub loadtest {
    my ($script) = @_;
    my $casedir = $bmwqemu::vars{CASEDIR};

    unless (-f join('/', $casedir, $script)) {
        warn "loadtest needs a script below $casedir - $script is not\n";
        $script = File::Spec->abs2rel($script, $bmwqemu::vars{CASEDIR});
    }
    unless ($script =~ m,(\w+)/([^/]+)\.pm$,) {
        die "loadtest needs a script to match \\w+/[^/]+.pm\n";
    }
    my $category = $1;
    my $name     = $2;
    my $test;
    my $fullname = "$category-$name";
    # perl code generating perl code is overcool
    # FIXME turn this into a proper eval instead of a generated string
    my $code = "package $name;";
    $code .= "use lib '$casedir/lib';";
    my $basename = dirname($script);
    $code .= "use lib '$casedir/$basename';";
    $code .= "require '$casedir/$script';";
    eval $code;    ## no critic
    if ($@) {
        my $msg = "error on $script: $@";
        bmwqemu::diag($msg);
        die $msg;
    }
    $test             = $name->new($category);
    $test->{script}   = $script;
    $test->{fullname} = $fullname;
    my $nr = '';
    while (exists $tests{$fullname . $nr}) {
        # to all perl hardcore hackers: fuck off!
        $nr = $nr eq '' ? 1 : $nr + 1;
        bmwqemu::diag($fullname . ' already scheduled');
    }
    $tests{$fullname . $nr} = $test;

    return unless $test->is_applicable;
    push @testorder, $test;
    bmwqemu::diag("scheduling $name$nr $script");
}

our $current_test;
our $last_milestone;

sub set_current_test {
    ($current_test) = @_;
    query_isotovideo('set_current_test', {name => ref($current_test)});
}

sub write_test_order {

    my @result;
    for my $t (@testorder) {
        push(
            @result,
            {
                name     => ref($t),
                category => $t->{category},
                flags    => $t->test_flags(),
                script   => $t->{script}});
    }
    bmwqemu::save_json_file(\@result, bmwqemu::result_dir . "/test_order.json");
}

sub make_snapshot {
    my ($sname) = @_;
    bmwqemu::diag("Creating a VM snapshot $sname");
    return query_isotovideo('backend_save_snapshot', {name => $sname});
}

sub load_snapshot {
    my ($sname) = @_;
    bmwqemu::diag("Loading a VM snapshot $sname");
    return query_isotovideo('backend_load_snapshot', {name => $sname});
}

sub run_all {
    my $died      = 0;
    my $completed = 0;
    eval { $completed = autotest::runalltests(); };
    if ($@) {
        warn $@;
        $died = 1;    # test execution died
    }
    bmwqemu::save_vars();
    myjsonrpc::send_json($isotovideo, {cmd => 'tests_done', died => $died, completed => $completed});
    close $isotovideo;
    _exit(0);
}

sub start_process {
    my $child;

    socketpair($child, $isotovideo, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
      or die "socketpair: $!";

    $child->autoflush(1);
    $isotovideo->autoflush(1);

    my $testpid = fork();
    if ($testpid) {
        close $isotovideo;
        return ($testpid, $child);
    }

    die "cannot fork: $!" unless defined $testpid;
    close $child;

    $SIG{TERM} = 'DEFAULT';
    $SIG{INT}  = 'DEFAULT';
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';

    cv::init;
    require tinycv;

    $0 = "$0: autotest";
    my $line = <$isotovideo>;
    if (!$line) {
        _exit(0);
    }
    print "GOT $line\n";
    # the backend process might have added some defaults for the backend
    bmwqemu::load_vars();

    run_all;
}


# TODO: define use case and reintegrate
sub prestart_hook {
    # run prestart test code before VM is started
    if (-f "$bmwqemu::vars{CASEDIR}/prestart.pm") {
        bmwqemu::diag "running prestart step";
        eval { require $bmwqemu::vars{CASEDIR} . "/prestart.pm"; };
        if ($@) {
            bmwqemu::diag "prestart step FAIL:";
            die $@;
        }
    }
}

# TODO: define use case and reintegrate
sub postrun_hook {
    # run postrun test code after VM is stopped
    if (-f "$bmwqemu::vars{CASEDIR}/postrun.pm") {
        bmwqemu::diag "running postrun step";
        eval { require "$bmwqemu::vars{CASEDIR}/postrun.pm"; };    ## no critic
        if ($@) {
            bmwqemu::diag "postrun step FAIL:";
            warn $@;
        }
    }
}

sub query_isotovideo {
    my ($cmd, $args) = @_;

    # deep copy
    my %json;
    if ($args) {
        %json = %$args;
    }
    $json{cmd} = $cmd;

    myjsonrpc::send_json($isotovideo, \%json);
    my $rsp = myjsonrpc::read_json($isotovideo);
    return $rsp->{ret};
}

sub runalltests {

    die "ERROR: no tests loaded" unless @testorder;

    my $firsttest           = $bmwqemu::vars{SKIPTO} || $testorder[0]->{fullname};
    my $vmloaded            = 0;
    my $snapshots_supported = query_isotovideo('backend_can_handle', {function => 'snapshots'});
    bmwqemu::diag "Snapshots are " . ($snapshots_supported ? '' : 'not ') . "supported";

    write_test_order();

    for my $t (@testorder) {
        my $flags    = $t->test_flags();
        my $fullname = $t->{fullname};

        if (!$vmloaded && $fullname eq $firsttest) {
            if ($bmwqemu::vars{SKIPTO}) {
                if ($bmwqemu::vars{TESTDEBUG}) {
                    load_snapshot('lastgood');
                }
                else {
                    load_snapshot($firsttest);
                }
            }
            $vmloaded = 1;
        }
        if ($vmloaded) {
            my $name = ref($t);
            bmwqemu::modstart "starting $name $t->{script}";
            $t->start();

            # avoid erasing the good vm snapshot
            if ($snapshots_supported && (($bmwqemu::vars{SKIPTO} || '') ne $fullname) && $bmwqemu::vars{MAKETESTSNAPSHOTS}) {
                make_snapshot($t->{fullname});
            }

            eval { $t->runtest; };
            $t->save_test_result();

            if ($@) {
                my $msg = $@;
                if ($msg !~ /^test.*died/) {
                    # avoid duplicating the message
                    bmwqemu::diag $msg;
                }
                if ($flags->{fatal} || !$snapshots_supported || $bmwqemu::vars{TESTDEBUG}) {
                    bmwqemu::stop_vm();
                    return 0;
                }
                elsif (!$flags->{norollback}) {
                    if ($last_milestone) {
                        load_snapshot('lastgood');
                        $last_milestone->rollback_activated_consoles();
                    }
                }
            }
            else {
                if ($snapshots_supported && ($flags->{milestone} || $bmwqemu::vars{TESTDEBUG})) {
                    make_snapshot('lastgood');
                    $last_milestone = $t;
                }
            }
        }
        else {
            bmwqemu::diag "skipping $fullname";
            $t->skip_if_not_running();
            $t->save_test_result();
        }
    }
    return 1;
}

sub loadtestdir {
    my $dir = shift;
    $dir =~ s/^\Q$bmwqemu::vars{CASEDIR}\E\/?//;    # legacy where absolute path is specified
    $dir = join('/', $bmwqemu::vars{CASEDIR}, $dir);    # always load from casedir
    die "$dir does not exist!\n" unless -d $dir;
    foreach my $script (glob "$dir/*.pm") {
        loadtest($script);
    }
}

1;

# vim: set sw=4 et:
