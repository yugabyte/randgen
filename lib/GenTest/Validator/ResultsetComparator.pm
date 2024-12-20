# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
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

package GenTest::Validator::ResultsetComparator;

require Exporter;
@ISA = qw(GenTest GenTest::Validator);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Comparator;
use GenTest::Result;
use GenTest::Validator;

sub validate {
	my ($comparator, $executors, $results) = @_;

	return STATUS_OK if $#$results != 1;

	my $query = $results->[0]->query();
	my $compare_outcome = GenTest::Comparator::compare($results->[0], $results->[1]);

	return STATUS_WONT_HANDLE if $results->[0]->status() == STATUS_SEMANTIC_ERROR || $results->[1]->status() == STATUS_SEMANTIC_ERROR;
	return STATUS_WONT_HANDLE if $results->[0]->status() == STATUS_SYNTAX_ERROR || $results->[1]->status() == STATUS_SYNTAX_ERROR;
	return STATUS_WONT_HANDLE if $results->[0]->query() =~ m{EXPLAIN}sio;
	return STATUS_WONT_HANDLE if $results->[0]->query() =~ m{ANALYZE}sio;

	if ( ($compare_outcome == STATUS_LENGTH_MISMATCH) ||
	     ($compare_outcome == STATUS_CONTENT_MISMATCH) 
	) {
		say("---------- RESULT COMPARISON ISSUE START ----------");
	}

	if ($compare_outcome == STATUS_LENGTH_MISMATCH) {
                my $is_select = ($query =~ s{/\*.+?\*/}{}sgor) =~ m{^\s*SELECT}sio;
                if ($is_select) {
                    say("Query: $query failed: result length mismatch between servers (".$results->[0]->rows()." vs. ".$results->[1]->rows().")");
                    say(GenTest::Comparator::dumpDiff($results->[0], $results->[1]));
                } else {
                    say("Query: $query failed: affected_rows mismatch between servers (".$results->[0]->affectedRows()." vs. ".$results->[1]->affectedRows().")");
                }
	} elsif ($compare_outcome == STATUS_CONTENT_MISMATCH) {
		say("Query: ".$results->[0]->query()." failed: result content mismatch between servers.");
		say(GenTest::Comparator::dumpDiff($results->[0], $results->[1]));
	}

	if ( ($compare_outcome == STATUS_LENGTH_MISMATCH) ||
	     ($compare_outcome == STATUS_CONTENT_MISMATCH) 
	) {
		say("---------- RESULT COMPARISON ISSUE END ------------");
	}

	#
	# If the discrepancy is found on SELECT, we reduce the severity of the error so that the test can continue
	# hopefully finding further errors in the same run or providing an indication as to how frequent the error is
	#
	# If the discrepancy is on an UPDATE, then the servers have diverged and the test can not continue safely.
	# 

	if ($query =~ m{^[\s/*!0-9]*(EXPLAIN|SELECT|ALTER|LOAD\s+INDEX|CACHE\s+INDEX)}io) {
		return $compare_outcome - STATUS_SELECT_REDUCTION;
	} else {
		return $compare_outcome;
	}
}

1;
