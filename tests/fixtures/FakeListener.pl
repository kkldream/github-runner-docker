#!/usr/bin/perl
# 明確的 FAKE Listener：不連線、不註冊、不執行 GitHub job。
# 保留實際 image 的 config.sh、env.sh、run.sh 與 run-helper.sh；只替換此 binary。
use strict;
use warnings;
use POSIX qw(WNOHANG);

sub marker {
    my ($name, $value) = @_;
    open my $file, '>', "fake-$name" or die "FAKE marker: $!";
    print {$file} "$value\n";
    close $file or die "FAKE marker close: $!";
}

$| = 1;
my $command = shift @ARGV // '';
if ($command eq 'configure') {
    my %args;
    while (@ARGV) {
        my $key = shift @ARGV;
        $args{$key} = $key =~ /^(--unattended|--replace|--ephemeral)$/
            ? 'true' : shift @ARGV;
    }
    die "FAKE only accepts fixture URL\n"
        unless ($args{'--url'} // '') eq 'https://github.com/example-org';
    die "FAKE only accepts fixture tokens\n"
        unless ($args{'--token'} // '') =~ /^FAKE-(ENV|FILE)-TOKEN$/;
    die "FAKE token-file precedence failed\n"
        unless $args{'--token'} eq ($ENV{FAKE_EXPECT_TOKEN} // 'FAKE-ENV-TOKEN');
    die "FAKE configure unexpectedly repeated\n" if -e 'fake-configured';
    marker('configured', 'FAKE configure called once; NOT GitHub registration');
    open my $runner, '>', '.runner' or die "FAKE .runner: $!";
    print {$runner} "{\"FAKE_TEST_ONLY\":true,\"NOT_REGISTERED\":true}\n";
    close $runner or die "FAKE .runner close: $!";
    print "FAKE_CONFIGURE_COMPLETE (NOT GitHub registration)\n";
    exit 0;
}
die "FAKE Listener only implements configure / run\n" unless $command eq 'run';
for my $key (qw(RUNNER_TOKEN RUNNER_TOKEN_FILE RUNNER_REGISTRATION_TOKEN)) {
    die "FAKE detected leaked token variable: $key\n" if exists $ENV{$key};
}
die "FAKE Listener must be non-root\n" if $< == 0;
marker('env-clean', 'registration token variables absent from FAKE Listener environment');
my $mode = $ENV{FAKE_LISTENER_MODE} // 'idle';
die "FAKE invalid mode\n" unless $mode eq 'idle' || $mode eq 'busy';
my $stop = '';
$SIG{INT} = sub { $stop ||= 'INT'; };
$SIG{TERM} = sub { $stop ||= 'TERM'; };
my $child;
if ($mode eq 'busy') {
    $child = fork();
    die "FAKE fork failed: $!" unless defined $child;
    if ($child == 0) {
        my $child_stop = '';
        $SIG{INT} = sub { $child_stop ||= 'INT'; };
        $SIG{TERM} = sub { $child_stop ||= 'TERM'; };
        marker('child-ready', "pid=$$ (synthetic work, NOT a GitHub job)");
        select undef, undef, undef, 0.05 until $child_stop;
        print "FAKE_CHILD_SIGNAL=$child_stop\n";
        # 模擬有界 drain；由 upstream process-group signal 直接到達，不由 FAKE parent 轉送。
        select undef, undef, undef, 1.0;
        marker('child-drained', $child_stop);
        print "FAKE_CHILD_DRAINED\n";
        exit 0;
    }
    my $deadline = time + 5;
    until (-e 'fake-child-ready') {
        die "FAKE child ready timeout\n" if time >= $deadline;
        select undef, undef, undef, 0.05;
    }
}
marker('ready', "FAKE mode=$mode pid=$$");
print "FAKE_LISTENER_READY mode=$mode uid=$<\n";
select undef, undef, undef, 0.05 until $stop;
print "FAKE_LISTENER_SIGNAL=$stop\n";
marker('signal', $stop);
if (defined $child) {
    my $deadline = time + 5;
    while (1) {
        my $result = waitpid($child, WNOHANG);
        if ($result == $child) {
            die "FAKE child failed\n" unless $? == 0;
            last;
        }
        die "FAKE waitpid failed\n" if $result == -1;
        die "FAKE child drain timeout\n" if time >= $deadline;
        select undef, undef, undef, 0.05;
    }
    die "FAKE child still exists after reap\n" if kill 0, $child;
    marker('child-reaped', 'synthetic child drained and reaped; NOT live job proof');
    print "FAKE_CHILD_REAPED\n";
}
marker('stopped', $stop);
print "FAKE_LISTENER_STOPPED\n";
exit 0;
