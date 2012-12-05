#!/usr/bin/perl

use strict;
use warnings;

use English qw(-no_match_vars);
use Test::More;

eval {
    require Test::Compile;
    Test::Compile->import();
};
plan(skip_all => 'Test::Compile required') if $EVAL_ERROR;

all_pm_files_ok(all_pm_files('urpm'));
