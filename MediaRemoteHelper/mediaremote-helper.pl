# MediaRemote-Helfer für Win7Taskbar.
#
# /usr/bin/perl ist von Apple signiert und darf die systemweite Wiedergabe-Info
# (MediaRemote) lesen, die macOS normalen Apps vorenthält. Dieses Skript lädt nur die
# dylib und übergibt an mr_run(), das dauerhaft läuft (Protokoll siehe MediaRemoteHelper.m).
#
# Aufruf: /usr/bin/perl mediaremote-helper.pl [/pfad/zu/libmediaremote-helper.dylib]
use strict;
use warnings;
use DynaLoader;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# dyld lehnt in Apple-Programmen relative Pfade ab, daher absolut machen.
my $path = abs_path($ARGV[0] // dirname(__FILE__) . "/libmediaremote-helper.dylib");
my $lib = DynaLoader::dl_load_file($path, 0)
    or die "mediaremote-helper: dylib nicht ladbar: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "mr_run")
    or die "mediaremote-helper: Symbol mr_run fehlt\n";
my $run = DynaLoader::dl_install_xsub("main::mr_run", $sym);
&$run();
