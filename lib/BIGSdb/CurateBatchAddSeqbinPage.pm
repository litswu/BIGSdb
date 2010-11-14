#Written by Keith Jolley
#Copyright (c) 2010, University of Oxford
#E-mail: keith.jolley@zoo.ox.ac.uk
#
#This file is part of Bacterial Isolate Genome Sequence Database (BIGSdb).
#
#BIGSdb is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#BIGSdb is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::CurateBatchAddSeqbinPage;
use strict;
use base qw(BIGSdb::CurateAddPage);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');
use Error qw(:try);
use BIGSdb::Page 'SEQ_METHODS';

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	print "<h1>Batch insert sequences</h1>\n";
	if ( $self->{'system'}->{'dbtype'} ne 'isolates' ) {
		print "<div class=\"box\" id=\"statusbad\"><p>This function can only be called for an isolate database.</p></div>\n";
		return;
	} elsif ( !$self->can_modify_table('sequence_bin') ) {
		print "<div class=\"box\" id=\"statusbad\"><p>Your user account is not allowed to upload sequences to the database.</p></div>\n";
		return;
	}
	if ( $q->param('checked_buffer') ) {
		my $dir      = $self->{'config'}->{'secure_tmp_dir'};
		my $tmp_file = $dir . '/' . $q->param('checked_buffer');
		open( my $file_fh, '<', $tmp_file );
		my @data = <$file_fh>;
		close $file_fh;
		$" = "\n";
		my $seq_ref;
		my $continue = 1;
		try {
			$seq_ref = BIGSdb::Utils::read_fasta( \"@data" );
		}
		catch BIGSdb::DataException with {
			$logger->error("Invalid FASTA file");
			$continue = 0;
		};
		if ( $tmp_file =~ /^(.*\/BIGSdb_[0-9_]+\.txt)$/ ) {
			$logger->info("Deleting temp file $tmp_file");
			unlink $1;
		} else {
			$logger->error("Can't delete temp file $tmp_file");
		}
		if ( !$continue ) {
			print "<div class=\"box\" id=\"statusbad\"><p>Unable to upload sequences.  Please try again.</p></div>\n";
			return;
		}
		my $qry =
"INSERT INTO sequence_bin (id,isolate_id,sequence,method,original_designation,comments,sender,curator,date_entered,datestamp) VALUES (?,?,?,?,?,?,?,?,?,?)";
		my $sql     = $self->{'db'}->prepare($qry);
		my $curator = $self->get_curator_id;
		eval {
			my $id;
			foreach ( keys %$seq_ref )
			{
				$id = $self->next_id('sequence_bin',0,$id);
				my ( $designation, $comments );
				if ( $_ =~ /(\S*)\s+(.*)/ ) {
					( $designation, $comments ) = ( $1, $2 );
				} else {
					$designation = $_;
				}
				my @values = (
					$id,          $q->param('isolate_id'), $seq_ref->{$_},      $q->param('method'),
					$designation, $comments,               $q->param('sender'), $curator,
					'today',      'today'
				);
				$sql->execute(@values);
			}
		};
		if ($@) {
			$" = ', ';
			print
			  "<div class=\"box\" id=\"statusbad\"><p>Database update failed - transaction cancelled - no records have been touched.</p>\n";
			if ( $@ =~ /duplicate/ && $@ =~ /unique/ ) {
				print
"<p>Data entry would have resulted in records with either duplicate ids or another unique field with duplicate values.</p>\n";
			} else {
				print "<p>Error message: $@</p>\n";
			}
			print "</div>\n";
			$self->{'db'}->rollback;
			return;
		} else {
			$self->{'db'}->commit;
			print "<div class=\"box\" id=\"resultsheader\"><p>Database updated ok</p>";
			print "<p><a href=\"" . $q->script_name . "?db=$self->{'instance'}\">Back to main page</a></p></div>\n";
		}
	} elsif ( $q->param('data') ) {
		my $continue = 1;
		if (   !$q->param('isolate_id')
			|| !BIGSdb::Utils::is_int( $q->param('isolate_id') )
			|| !$self->{'datastore'}
			->run_simple_query( "SELECT COUNT(*) FROM $self->{'system'}->{'view'} WHERE id=?", $q->param('isolate_id') )->[0] )
		{
			print "<div class=\"box\" id=\"statusbad\"><p>Isolate id must be an integer and exist in the isolate table.</p></div>\n";
			$continue = 0;
		} elsif ( ( $self->{'system'}->{'read_access'} eq 'acl' || $self->{'system'}->{'write_access'} eq 'acl' )
			&& $self->{'username'}
			&& !$self->is_admin
			&& !$self->is_allowed_to_view_isolate( $q->param('isolate_id') ) )
		{
			print "<div class=\"box\" id=\"statusbad\"><p>Your user account is not allowed to modify this isolate record.</p></div>\n";
			$continue = 0;
		} elsif ( !$q->param('sender')
			|| !BIGSdb::Utils::is_int( $q->param('sender') )
			|| !$self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM users WHERE id=?", $q->param('sender') )->[0] )
		{
			print "<div class=\"box\" id=\"statusbad\"><p>Sender is required and must exist in the users table.</p></div>\n";
			$continue = 0;
		}
		my $seq_ref;
		if ($continue) {
			try {
				$seq_ref = BIGSdb::Utils::read_fasta( \$q->param('data') );
			}
			catch BIGSdb::DataException with {
				my $ex = shift;
				if ( $ex =~ /DNA/ ) {
					my $header;
					if ( $ex =~ /DNA (.*)$/ ) {
						$header = $1;
					}
					print
					  "<div class=\"box\" id=\"statusbad\"><p>FASTA data '$header' contains non-valid nucleotide characters.</p></div>\n";
					$continue = 0;
				} else {
					print "<div class=\"box\" id=\"statusbad\"><p>Sequence data is not in valid FASTA format.</p></div>\n";
					$continue = 0;
				}
			};
		}
		if ($continue) {
			my @checked_buffer;
			print "<div class=\"box\" id=\"resultstable\"><p>The following sequences will be entered.</p>\n";
			print "<table><tr><td>";
			print "<table class=\"resultstable\"><tr><th>Original designation</th><th>Sequence length</th><th>Comments</th></tr>\n";
			my $td = 1;
			my $min_size = 0;
			if ($q->param('size_filter') && BIGSdb::Utils::is_int($q->param('size'))){
				$min_size = $q->param('size_filter') && $q->param('size');
			}
			foreach ( sort { $a cmp $b } keys %$seq_ref ) {
				my $length = length( $seq_ref->{$_} );
				next if $length < $min_size;
				push @checked_buffer, ">$_";
				push @checked_buffer, $seq_ref->{$_};
				my ( $designation, $comments );
				if ( $_ =~ /(\S*)\s+(.*)/ ) {
					( $designation, $comments ) = ( $1, $2 );
				} else {
					$designation = $_;
				}
				
				print "<tr class=\"td$td\"><td>$designation</td><td>$length</td><td>$comments</td></tr>\n";
				$td = $td == 1 ? 2 : 1;
			}
			print "</table>\n";
			print "</td><td style=\"padding-left:2em; vertical-align:top\">\n";
			my $num;
			my ( $min, $max, $mean, $total );
			foreach ( values %$seq_ref ) {
				my $length = length $_;
				next if $length < $min_size;
				$min = $length if !$min || $length < $min;
				$max = $length if $length > $max;
				$total += $length;
				$num++;
			}
			$mean = int $total / $num if $num;
			print "<ul><li>Number of contigs: $num</li>\n";
			print "<li>Minimum length: $min</li>\n";
			print "<li>Maximum length: $max</li>\n";
			print "<li>Total length: $total</li>\n";
			print "<li>Mean length: $mean</li></ul>\n";
			print $q->start_form;
			print $q->submit( -name => 'Upload', -class => 'submit' );
			my $filename = $self->make_temp_file(@checked_buffer);
			$q->param( 'checked_buffer', $filename );

			foreach (qw (db page checked_buffer isolate_id sender method comments)) {
				print $q->hidden($_);
			}
			print $q->end_form;
			print "</td></tr></table>\n";
			print "</div>";
		}
	} else {
		print
"<div class=\"box\" id=\"queryform\"><p>This page allows you to upload sequence data for a specified isolate record in FASTA format.</p>\n";
		print $q->start_form;
		my $qry = "select id,user_name,first_name,surname from users WHERE id>0 order by surname";
		my $sql = $self->{'db'}->prepare($qry);
		eval { $sql->execute(); };
		if ($@) {
			$logger->error("Can't execute: $qry");
		} else {
			$logger->debug("Query: $qry");
		}
		my @users;
		my %usernames;
		while ( my ( $userid, $username, $firstname, $surname ) = $sql->fetchrow_array ) {
			push @users, $userid;
			$usernames{$userid} = "$surname, $firstname ($username)";
		}
		$qry = "SELECT id,$self->{'system'}->{'labelfield'} FROM $self->{'system'}->{'view'} ORDER BY id";
		$sql = $self->{'db'}->prepare($qry);
		eval { $sql->execute; };
		if ($@) {
			$logger->error("Can't execute $qry; $@");
		}
		my $id_arrayref = $sql->fetchall_arrayref;
		print "<p>Please fill in the following fields - required fields are marked with an exclamation mark (!).</p>\n";
		print "<table><tr><td>\n";
		print "<table><tr>";
		print "<td style=\"text-align:right\">isolate id: !</td><td>";
		if ( scalar @$id_arrayref < 20000 ) {
			my @ids = '';
			my %labels;
			foreach (@$id_arrayref) {
				push @ids, $_->[0];
				$labels{ $_->[0] } = "$_->[0]) $_->[1]";
			}
			print $q->popup_menu( -name => 'isolate_id', -values => \@ids, -labels => \%labels );
		} else {
			print $q->textfield( -name => 'isolate_id', -size => 12 );
		}
		print "</td></tr>\n<tr><td style=\"text-align:right\">sender: !</td><td>\n";
		print $q->popup_menu( -name => 'sender', -values => [ '', @users ], -labels => \%usernames );
		print "</td></tr>\n<tr><td style=\"text-align:right\">method: </td><td>";
		print $q->popup_menu( -name => 'method', -values => [ '', SEQ_METHODS ] );
		print "</td></tr></table>";
		print "</td><td style=\"padding-left:2em; vertical-align:top\">\n";
		print $q->checkbox(-name=>'size_filter', -label=> "Don't insert sequences shorter than ", -checked=>'checked');
		print $q->popup_menu(-name=>'size', -values => [qw(25 50 100 250 500 1000)], -default=>250);
		print " bps.";
		print "</td></tr></table>\n";
		print "<p />\n";
		print "<p>Please paste in sequences in FASTA format:</p>\n";
		foreach (qw (page db)) {
			print $q->hidden($_);
		}
		print $q->textarea( -name => 'data', -rows => 20, -columns => 120 );
		print "<table style=\"width:95%\"><tr><td>";
		print $q->reset( -class => 'reset' );
		print "</td><td style=\"text-align:right\">";
		print $q->submit( -class => 'submit' );
		print "</td></tr></table><p />\n";
		print $q->end_form;
		print "<p><a href=\"" . $q->script_name . "/?db=$self->{'instance'}\">Back</a></p>\n";
		print "</div>\n";
	}
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return "Batch add new sequences - $desc";
}
1;
