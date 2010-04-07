#!/usr/bin/perl

# Copyright (c) 2008,2010 Oracle and/or its affiliates. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

package GenTest::App::GenTest;

@ISA = qw(GenTest);

use strict;
use Carp;
use Data::Dumper;

use GenTest;
use GenTest::Properties;
use GenTest::Constants;
use GenTest::App::Gendata;
use GenTest::App::GendataSimple;
use GenTest::IPC::Channel;
use GenTest::IPC::Process;
use GenTest::ErrorFilter;

use POSIX;
use Time::HiRes;

use GenTest::XML::Report;
use GenTest::XML::Test;
use GenTest::XML::BuildInfo;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use GenTest::Generator::FromGrammar;
use GenTest::Executor;
use GenTest::Mixer;
use GenTest::Reporter;
use GenTest::ReporterManager;
use GenTest::Filter::Regexp;

use constant PROCESS_TYPE_PARENT	=> 0;
use constant PROCESS_TYPE_PERIODIC	=> 1;
use constant PROCESS_TYPE_CHILD		=> 2;

use constant GT_CONFIG => 0;

sub new {
    my $class = shift;
    
    my $self = $class->SUPER::new({
        'config' => GT_CONFIG},@_);
    
    croak ("Need config") if not defined $self->config;

    return $self;
}

sub config {
    return $_[0]->[GT_CONFIG];
}

sub run {
    my ($self) = @_;

    $| = 1;
    my $ctrl_c = 0;
    
    $SIG{INT} = sub { $ctrl_c = 1 };
    $SIG{TERM} = sub { exit(0) };
    $SIG{CHLD} = "IGNORE" if windows();
    
    if (defined $ENV{RQG_HOME}) {
        $ENV{RQG_HOME} = windows() ? $ENV{RQG_HOME}.'\\' : $ENV{RQG_HOME}.'/';
    }
    
    my $seed = $self->config->seed;
    if ($seed eq 'time') {
        $seed = time();
        say("Converting --seed=time to --seed=$seed");
    }
    
    $ENV{RQG_DEBUG} = 1 if $self->config->debug;

    my $queries = $self->config->queries;
    $queries =~ s{K}{000}so;
    $queries =~ s{M}{000000}so;

    say("-------------------------------\nConfiguration");
    $self->config->printProps;

    if ((defined $self->config->gendata) && 
        (not defined $self->config->property('start-dirty'))) {
        foreach my $dsn (@{$self->config->dsn}) {
            next if $dsn eq '';
            my $gendata_result;
            my $datagen;
            if ($self->config->gendata eq '') {
                $datagen = GenTest::App::GendataSimple->new(dsn => $dsn,
                                                            views => $self->config->views,
                                                            engine => $self->config->engine);
            } else {
                $datagen = GenTest::App::Gendata->new(spec_file => $self->config->gendata,
                                                      dsn => $dsn,
                                                      engine => $self->config->engine,
                                                      seed => $seed,
                                                      debug => $self->config->debug,
                                                      rows => $self->config->rows,
                                                      views => $self->config->views,
                                                      varchar_length => $self->config->property('varchar-length'));
            }
            $gendata_result = $datagen->run();
            
            return ($gendata_result >> 8) if $gendata_result > STATUS_OK;
        }
    }
    
    my $test_start = time();
    my $test_end = $test_start + $self->config->duration;
    
    my $grammar = GenTest::Grammar->new(
        grammar_file => $self->config->grammar
        );
    
    return STATUS_ENVIRONMENT_FAILURE if not defined $grammar;
    
    if (defined $self->config->redefine) {
        my $patch_grammar = GenTest::Grammar->new(
            grammar_file => $self->config->redefine);
        $grammar = $grammar->patch($patch_grammar);
    }
    
    return STATUS_ENVIRONMENT_FAILURE if not defined $grammar;
    
    my $channel = GenTest::IPC::Channel->new();
    
    my @executors;
    foreach my $i (0..2) {
        next if $self->config->dsn->[$i] eq '';
        push @executors, GenTest::Executor->newFromDSN($self->config->dsn->[$i],
                                                       windows()?undef:$channel);
    }
    
    my $drizzle_only = $executors[0]->type == DB_DRIZZLE;
    $drizzle_only = $drizzle_only && $executors[1]->type == DB_DRIZZLE if $#executors > 0;
    
    my $mysql_only = $executors[0]->type == DB_MYSQL;
    $mysql_only = $mysql_only && $executors[1]->type == DB_MYSQL if $#executors > 0;
    
    if (not defined $self->config->reporters or $#{$self->config->reporters} < 0) {
        $self->config->reporters([]);
        if ($mysql_only || $drizzle_only) {
            $self->config->reporters(['ErrorLog', 'Backtrace']);
        }
    } else {
        ## Remove the "None" reporter
        foreach my $i (0..$#{$self->config->reporters}) {
            delete $self->config->reporters->[$i] 
                if $self->config->reporters->[$i] eq "None" 
                or $self->config->reporters->[$i] eq '';
        }
    }
    
    say("Reporters: ".($#{$self->config->reporters} > -1 ? join(', ', @{$self->config->reporters}) : "(none)"));
    
    my $reporter_manager = GenTest::ReporterManager->new();
    
    if ($mysql_only ) {
        foreach my $i (0..2) {
            next if $self->config->dsn->[$i] eq '';
            foreach my $reporter (@{$self->config->reporters}) {
                my $add_result = $reporter_manager->addReporter($reporter, {
                    dsn			=> $self->config->dsn->[$i],
                    test_start	=> $test_start,
                    test_end	=> $test_end,
                    test_duration	=> $self->config->duration
                                                                } );
                return $add_result if $add_result > STATUS_OK;
            }
        }
    }

    if (not defined $self->config->validators or $#{$self->config->validators} < 0) {
        $self->config->validators([]);
        push(@{$self->config->validators}, 'ErrorMessageCorruption') 
            if ($mysql_only || $drizzle_only);
        if ($self->config->dsn->[2] ne '') {
            push @{$self->config->validators}, 'ResultsetComparator3';
        } elsif ($self->config->dsn->[1] ne '') {
            push @{$self->config->validators}, 'ResultsetComparator';
        }
        
        push @{$self->config->validators}, 'ReplicationSlaveStatus' 
            if $self->config->rpl_mode ne '' && ($mysql_only || $drizzle_only);
        push @{$self->config->validators}, 'MarkErrorLog' 
            if (defined $self->config->valgrind) && ($mysql_only || $drizzle_only);
        
        push @{$self->config->validators}, 'QueryProperties' 
            if $grammar->hasProperties() && ($mysql_only || $drizzle_only);
    } else {
        ## Remove the "None" validator
        foreach my $i (0..$#{$self->config->validators}) {
            delete $self->config->validators->[$i] 
                if $self->config->validators->[$i] eq "None"
                or $self->config->validators->[$i] eq '';
        }
    }
    say("Validators: ".($self->config->validators and $#{$self->config->validators} > -1 ? join(', ', @{$self->config->validators}) : "(none)"));
    
    my $filter_obj;
    
    $filter_obj = GenTest::Filter::Regexp->new( file => $self->config->filter ) 
        if defined $self->config->filter;
    
    say("Starting ".$self->config->threads." processes, ".
        $self->config->queries." queries each, duration ".
        $self->config->duration." seconds.");
    
    my $buildinfo;
    if (defined $self->config->property('xml-output')) {
        $buildinfo = GenTest::XML::BuildInfo->new(
            dsns => $self->config->dsn
            );
    }
    
    my $test = GenTest::XML::Test->new(
        id => Time::HiRes::time(),
        attributes => {
            engine => $self->config->engine,
            gendata => $self->config->gendata,
            grammar => $self->config->grammar,
            threads => $self->config->threads,
            queries => $self->config->queries,
            validators => join (',', @{$self->config->validators}),
            reporters => join (',', @{$self->config->reporters}),
            seed => $seed,
            mask => $self->config->mask,
            mask_level => $self->config->property('mask-level'),
            rows => $self->config->rows,
            'varchar-length' => $self->config->property('varchar-length')
        }
        );
    
    my $report = GenTest::XML::Report->new(
        buildinfo => $buildinfo,
        tests => [ $test ]
        );

    ### Start central reporting thread ####
    
    my $errorfilter = GenTest::ErrorFilter->new(channel=>$channel);
    my $errorfilter_p = GenTest::IPC::Process->new(object=>$errorfilter);
    if (!windows()) {
        $errorfilter_p->start();
    }
    
    ### Start children ###

    my $process_type;
    my %child_pids;
    my $id = 1;
    
    my $periodic_pid = fork();
    if ($periodic_pid == 0) {
        Time::HiRes::sleep(($self->config->threads + 1) / 10);
        say("Started periodic reporting process...");
        $process_type = PROCESS_TYPE_PERIODIC;
        $id = 0;
    } else {
        foreach my $i (1..$self->config->threads) {
            my $child_pid = fork();
            $channel->writer;
            if ($child_pid == 0) { # This is a child 
                $process_type = PROCESS_TYPE_CHILD;
                last;
            } else {
                $child_pids{$child_pid} = 1;
                $process_type = PROCESS_TYPE_PARENT;
                $seed++;
                $id++;
                Time::HiRes::sleep(0.1);	# fork slowly for more predictability
                next;
            }
        }
    }


    ### Do the job

    if ($process_type == PROCESS_TYPE_PARENT) {
        
        ### Main process
        
        if (windows()) {
            ## Important that this is done here in the parent after the last
            ## fork since on windows Process.pm uses threads
            $errorfilter_p->start();
        }
        # We are the parent process, wait for for all spawned processes to terminate
        my $children_died = 0;
        my $total_status = STATUS_OK;
        my $periodic_died = 0;
        
        ## Parent thread does not use channel
        $channel->close;
        
        while (1) {
            my $child_pid = wait();
            my $exit_status = $? > 0 ? ($? >> 8) : 0;

            $total_status = $exit_status if $exit_status > $total_status;
            
            if ($child_pid == $periodic_pid) {
                $periodic_died = 1;
                last;
            } else {
                $children_died++;
                delete $child_pids{$child_pid};
            }
            
            last if $exit_status >= STATUS_CRITICAL_FAILURE;
            last if $children_died == $self->config->threads;
            last if $child_pid == -1;
        }

        foreach my $child_pid (keys %child_pids) {
            say("Killing child process with pid $child_pid...");
            kill(15, $child_pid);
        }
        
        if ($periodic_died == 0) {
            # Wait for periodic process to return the status of its last execution
            Time::HiRes::sleep(1);
            say("Killing periodic reporting process with pid $periodic_pid...");
            kill(15, $periodic_pid);
            
            if (windows()) {
                # We use sleep() + non-blocking waitpid() due to a bug in ActiveState Perl
                Time::HiRes::sleep(1);
                waitpid($periodic_pid, &POSIX::WNOHANG() );
            } else {
                waitpid($periodic_pid, 0);
            }
            
            if ($? > -1 ) {
                my $periodic_status = $? > 0 ? $? >> 8 : 0;
                $total_status = $periodic_status if $periodic_status > $total_status;
            }
        }
        
        $errorfilter_p->kill();
        
        my @report_results;
        
        if ($total_status == STATUS_OK) {
            @report_results = $reporter_manager->report(REPORTER_TYPE_SUCCESS | REPORTER_TYPE_ALWAYS);
        } elsif (
            ($total_status == STATUS_LENGTH_MISMATCH) ||
            ($total_status == STATUS_CONTENT_MISMATCH)
            ) {
            @report_results = $reporter_manager->report(REPORTER_TYPE_DATA);
        } elsif ($total_status == STATUS_SERVER_CRASHED) {
            say("Server crash reported, initiating post-crash analysis...");
            @report_results = $reporter_manager->report(REPORTER_TYPE_CRASH | REPORTER_TYPE_ALWAYS);
        } elsif ($total_status == STATUS_SERVER_DEADLOCKED) {
            say("Server deadlock reported, initiating analysis...");
            @report_results = $reporter_manager->report(REPORTER_TYPE_DEADLOCK | REPORTER_TYPE_ALWAYS);
        } elsif ($total_status == STATUS_SERVER_KILLED) {
            @report_results = $reporter_manager->report(REPORTER_TYPE_SERVER_KILLED | REPORTER_TYPE_ALWAYS);
        } else {
            @report_results = $reporter_manager->report(REPORTER_TYPE_ALWAYS);
        }
        
        my $report_status = shift @report_results;
        $total_status = $report_status if $report_status > $total_status;
        $total_status = STATUS_OK if $total_status == STATUS_SERVER_KILLED;
        
        foreach my $incident (@report_results) {
            $test->addIncident($incident);
        }
        
        $test->end($total_status == STATUS_OK ? "pass" : "fail");
        
        if (defined $self->config->property('xml-output')) {
            open (XML , ">$self->config->property('xml-output')") or say("Unable to open $self->config->property('xml-output'): $!");
            print XML $report->xml();
            close XML;
        }
        
        if ($total_status == STATUS_OK) {
            say("Test completed successfully.");
            return STATUS_OK;
        } else {
            say("Test completed with failure status $total_status.");
            return $total_status;
        }
    } elsif ($process_type == PROCESS_TYPE_PERIODIC) {
        ## Periodic does not use channel
        $channel->close();
        while (1) {
            my $reporter_status = $reporter_manager->monitor(REPORTER_TYPE_PERIODIC);
            $self->stop_child($reporter_status) if $reporter_status > STATUS_CRITICAL_FAILURE;
            sleep(10);
        }
        $self->stop_child(STATUS_OK);
    } elsif ($process_type == PROCESS_TYPE_CHILD) {

        # We are a child process, execute the desired queries and terminate
        
        my $generator = GenTest::Generator::FromGrammar->new(
            grammar => $grammar,
            varchar_length => $self->config->property('varchar-length'),
            seed => $seed + $id,
            thread_id => $id,
            mask => $self->config->mask,
	        mask_level => $self->config->property('mask-level')
            );
        
        $self->stop_child(STATUS_ENVIRONMENT_FAILURE) if not defined $generator;
        
        my $mixer = GenTest::Mixer->new(
            generator => $generator,
            executors => \@executors,
            validators => $self->config->validators,
            filters => defined $filter_obj ? [ $filter_obj ] : undef
            );
        
        $self->stop_child(STATUS_ENVIRONMENT_FAILURE) if not defined $mixer;
        
        my $max_result = 0;
        
        foreach my $i (1..$queries) {
            my $result = $mixer->next();
            $self->stop_child($result) if $result > STATUS_CRITICAL_FAILURE;

            $max_result = $result if $result > $max_result && $result > STATUS_TEST_FAILURE;
            last if $result == STATUS_EOF;
            last if $ctrl_c == 1;
            last if time() > $test_end;
        }
        
        for my $ex (@executors) {
            $ex->disconnect;
        }
        
        if ($max_result > 0) {
            say("Child process completed with error code $max_result.");
            $self->stop_child($max_result);
        } else {
            say("Child process completed successfully.");
            $self->stop_child(STATUS_OK);
        }
    } else {
        croak ("Unknown process type $process_type");
    }

}

sub stop_child {
    my ($self, $status) = @_;

    die "calling stop_child() without a \$status" if not defined $status;

    if (windows()) {
        exit $status;
    } else {
        safe_exit($status);
    }
}

1;