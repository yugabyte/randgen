#!/usr/bin/perl

# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
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

use strict;
use lib 'lib';
use lib '../lib';
use DBI;

use GenTest::Constants;
use GenTest::Executor::Postgres;
use GenTest::Simplifier::SQL;
use GenTest::Simplifier::Test;

#
# Please modify those settings to fit your environment before you run this script
#

my $basedir = '/Users/mtakahara/code/yugabyte-db/';
my $dsn = 'dbi:Pg:host=127.0.0.1;port=5433;user=yugabyte;database=test';
my $duration = 3600;

my $original_query = "
SELECT 1
";

# Optional prefix for hints/EXPLAIN, etc.
my $prefix = "";
##my $prefix = "/*+ Set(enable_hashjoin off) Set(enable_mergejoin off) Set(enable_material off) */";


# Maximum number of seconds a query will be allowed to proceed. It is assumed that most crashes will happen immediately after takeoff
my $timeout = 10000;            # 10 sec

my $ybctl_cmd = "./bin/yb-ctl stop; ./bin/yb-ctl start --tserver_flags 'ysql_beta_features=1,ysql_log_statement=all' --timeout-processes-running-sec 600 --timeout-yb-admin-sec 600";


my $orig_database = 'test';
my $new_database = 'crash';

my $executor;

start_server();

my $simplifier = GenTest::Simplifier::SQL->new(
	oracle => sub {
		my $oracle_query = shift;
		my $dbh = $executor->dbh();
	
		$dbh->do("SET statement_timeout = $timeout");

		$executor->execute($prefix.$oracle_query);

		# Or, alternatively, execute as a prepared statement
		# $executor->execute("PREPARE prep_stmt FROM \"$oracle_query\"");
		# $executor->execute("EXECUTE prep_stmt");
		# $executor->execute("EXECUTE prep_stmt");
		# $executor->execute("DEALLOCATE PREPARE prep_stmt");

		if (!$executor->dbh()->ping()) {
			start_server();
			return ORACLE_ISSUE_STILL_REPEATABLE;
		} else {
			return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
		}
	}
);

my $simplified_query = $simplifier->simplify($original_query);

if (!$simplified_query or ($prefix and $simplified_query =~ /$prefix/)) {
    print "\nFailed to simplify the query\n";
    exit;
}
print "\nSimplified query:\n$prefix$simplified_query;\n\n";


my $simplifier_test = GenTest::Simplifier::Test->new(
	executors => [ $executor ],
	queries => [ $simplified_query , $original_query ]
);

my $simplified_test = $simplifier_test->simplify();

print "Simplified test\n\n";
print $simplified_test;

sub start_server {
	chdir($basedir) or die "Unable to chdir() to $basedir: $!";

	$executor = GenTest::Executor::Postgres->new( dsn => $dsn, end_time => time() + $duration );
	$executor->init() if defined $executor;

	if ((not defined $executor) || (not defined $executor->dbh()) || (!$executor->dbh()->ping())) {
            system($ybctl_cmd);
            $executor = GenTest::Executor::Postgres->new( dsn => $dsn, end_time => time() + $duration );
            $executor->init();
	}
}
