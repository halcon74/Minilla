package Minilla::Release::RunHooks;
use strict;
use warnings;
use utf8;

use Minilla::Logger ();

sub run {
    my ($self, $project, $opts) = @_;

    my $return_value = 0;
    my $commands     = $project->config->{release}->{hooks};

    if ($commands) {
        if (ref $commands ne 'ARRAY') {
            warn "Release hooks must be array";
            exit 1;
        }
        my $join = "";
        for my $command (@{$commands}) {
                $join and $join .= " && ";
                $join .= "$command"
        }
        Minilla::Logger::infof("Running hook: %s\n", $join);
        $return_value = system ("$join");
    }

    if ($return_value != 0) {
        # Failure executing command of hooks
        exit 1;
    }
}

1;

