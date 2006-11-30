package helper;

use Test::More;

my $using_root;
sub need_root_and_prepare() {
    if ($< != 0) {
	#- can't test
	pass();
	exit(0);
    }
    -d 'media' or die "02create_pkgs.t not done\n";

    system('rm -rf root');
    isnt(-d 'root', "test root dir can not be removed $!");
    mkdir 'root';
    $using_root = 1;
}

chomp($::pwd = `pwd`);
my $urpmi_debug_opt = '-q';#'-v --debug';

sub urpmi_addmedia {
    my ($para) = @_;
    system_("perl -I.. ../urpmi.addmedia $urpmi_debug_opt --urpmi-root $::pwd/root $para");
}
sub urpmi {
    my ($para) = @_;
    system_("perl -I.. ../urpmi $urpmi_debug_opt --urpmi-root $::pwd/root --ignoresize $para");
}

sub system_ {
    my ($cmd) = @_;
    system($cmd);
    ok($? == 0, $cmd);
}

END { $using_root and system('rm -rf root') }

1;
