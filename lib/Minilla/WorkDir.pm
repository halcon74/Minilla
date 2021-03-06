package Minilla::WorkDir;
use strict;
use warnings;
use utf8;
use Archive::Tar;
use File::pushd;
use Data::Dumper; # serializer
use File::Spec::Functions qw(splitdir);
use File::Spec;
use Time::Piece qw(gmtime);
use File::Basename qw(dirname);
use File::Path qw(mkpath);
use File::Copy qw(copy);
use Config;

use Minilla::Logger;
use Minilla::Util qw(randstr cmd cmd_perl slurp slurp_raw spew spew_raw pod_escape run_steps);
use Minilla::FileGatherer;
use Minilla::ReleaseTest;

use Moo;

has project => (
    is => 'ro',
    required => 1,
    handles => [qw(files)],
);

has dir => (
    is => 'lazy',
    isa => sub {
        Carp::confess("'dir' must not be undef") unless defined $_[0];
    },
);

has manifest_files => (
    is => 'lazy',
);

has [qw(prereq_specs)] => (
    is => 'lazy',
);

has 'cleanup' => (
    is => 'ro',
    default => sub { $Minilla::DEBUG ? 0 : 1 },
);

has changes_time => (
    is => 'lazy',
);

no Moo;

sub _build_changes_time { scalar(gmtime()) }

sub DEMOLISH {
    my $self = shift;
    if ($self->cleanup) {
        infof("Removing %s\n", $self->dir);
        File::Path::rmtree($self->dir)
    }
}

sub _build_dir {
    my $self = shift;
    my $dirname = $^O eq 'MSWin32' ? '_build' : '.build';
    File::Spec->catfile($self->project->dir, $dirname, randstr(8));
}

sub _build_prereq_specs {
    my $self = shift;

    my $cpanfile = Module::CPANfile->load(File::Spec->catfile($self->project->dir, 'cpanfile'));
    return $cpanfile->prereq_specs;
}

sub _build_manifest_files {
    my $self = shift;
    my @files = (@{$self->files}, qw(LICENSE META.json META.yml MANIFEST));
    if (-f File::Spec->catfile($self->dir, 'Makefile.PL')) {
        push @files, 'Makefile.PL';
    } else {
        push @files, 'Build.PL';
    }

    [do {
        my %h;
        grep {!$h{$_}++} @files;
    }];
}

sub as_string {
    my $self = shift;
    $self->dir;
}

sub BUILD {
    my ($self) = @_;

    infof("Creating working directory: %s\n", $self->dir);

    # copying
    mkpath($self->dir);
    for my $src (@{$self->files}) {
        next if -d $src;
        debugf("Copying %s\n", $src);

        if (not -e $src) {
            warnf("Trying to copy non-existing file '$src', ignored\n");
            next;
        }
        my $dst = File::Spec->catfile($self->dir, File::Spec->abs2rel($src, $self->project->dir));
        mkpath(dirname($dst));
        infof("cp %s %s\n", $src, $dst);
        copy($src => $dst) or die "Copying failed: $src $dst, $!\n";
        chmod((stat($src))[2], $dst) or die "Cannot change mode: $dst, $!\n";
    }
}

sub build {
    my ($self) = @_;

    return if $self->{build}++;

    my $guard = pushd($self->dir);

    infof("Building %s\n", $self->dir);

    # Generate meta file
    {
        my $meta = $self->project->cpan_meta();
        $meta->save('META.yml', {
            version => 1.4,
        });
        $meta->save('META.json', {
            version => 2.0,
        });
    }

    {
        infof("Writing MANIFEST file\n");
        spew('MANIFEST', join("\n", @{$self->manifest_files}));
    }

    $self->project->regenerate_files();
    $self->_rewrite_changes();
    $self->_rewrite_pod();

    unless ($ENV{MINILLA_DISABLE_WRITE_RELEASE_TEST}) { # DO NOT USE THIS ENVIRONMENT VARIABLE.
        Minilla::ReleaseTest->write_release_tests($self->project, $self->dir);
    }

    if (-f 'Build.PL') {
        cmd_perl('Build.PL');
        cmd_perl('Build', 'build');
    } elsif (-f 'Makefile.PL') {
        cmd_perl('Makefile.PL');
        cmd($Config{make});
    } else {
       die "There is no Makefile.PL/Build.PL";
    }
}

sub _rewrite_changes {
    my $self = shift;

    my $orig = slurp_raw('Changes');
    $orig =~ s!\{\{\$NEXT\}\}!
        $self->project->version . ' ' . $self->changes_time->strftime('%Y-%m-%dT%H:%M:%SZ')
    !e;
    spew_raw('Changes', $orig);
}

sub _rewrite_pod {
    my $self = shift;

    # Disabled this feature.
#   my $orig =slurp_raw($self->project->main_module_path);
#   if (@{$self->project->contributors}) {
#       $orig =~ s!
#           (^=head \d \s+ (?:authors?)\b \s*)
#           (.*?)
#           (^=head \d \s+ | \z)
#       !
#           (       $1
#               . $2
#               . "=head1 CONTRIBUTORS\n\n=over 4\n\n"
#               . join( '', map { "=item $_\n\n" } map { pod_escape($_) } @{ $self->project->contributors } )
#               . "=back\n\n"
#               . $3 )
#       !ixmse;
#       spew_raw($self->project->main_module_path => $orig);
#   }
}

# Return non-zero if fail
sub dist_test {
    my ($self, @targets) = @_;

    $self->build();

    $self->project->verify_prereqs();

    eval {
        my $guard = pushd($self->dir);
        $self->project->module_maker->run_tests();
    };
    return $@ ? 1 : 0;
}

sub dist {
    my ($self) = @_;

    $self->{tarball} ||= do {
        my $steps = [ qw(
            RunHooks
        ) ];
        run_steps ($steps, $self->project);

        $self->build();

        my $guard = pushd($self->dir);

        # Create tar ball
        my $tarball = sprintf('%s-%s.tar.gz', $self->project->dist_name, $self->project->version);

        my $force_mode = 0;

        my $tar = Archive::Tar->new;
        for my $file (@{$self->manifest_files}) {
            my $filename = File::Spec->catfile($self->project->dist_name . '-' . $self->project->version, $file);
            my $data = slurp($file);

            my $mode = (stat($file))[2];

            # On Windows, (stat($file))[2] * ALWAYS * results in octal 0100666 (which means it is
            # world writeable). World writeable files are always rejected by PAUSE. The solution is to
            # change a file mode octal 0100666 to octal 000664, such that it is * NOT * world
            # writeable. This works on Windows, as well as on other systems (Linux, Mac, etc...), because
            # the filemode 0100666 only occurs on Windows. (If it occurred on Linux, it would be wrong anyway)

            if ($mode == 0100666) {
                $mode = 0644;
                $force_mode++;
            }

            $tar->add_data($filename, $data, { mode => $mode });
        }
        $tar->write($tarball, COMPRESS_GZIP);
        infof("Wrote %s\n", $tarball.($force_mode == 0 ? '' : ' --> forced to mode 000664'));

        File::Spec->rel2abs($tarball);
    };
}

sub run {
    my ($self, @cmd) = @_;
    $self->build();

    eval {
        my $guard = pushd($self->dir);
        cmd(@cmd);
    };
    return $@ ? 1 : 0;
}

1;
