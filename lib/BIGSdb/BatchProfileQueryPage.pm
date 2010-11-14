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
package BIGSdb::BatchProfileQueryPage;
use strict;
use base qw(BIGSdb::Page);
use Log::Log4perl qw(get_logger);
use Error qw(:try);
my $logger = get_logger('BIGSdb.Page');

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return "Batch profile query - $desc";
}

sub initiate {
	my ($self) = @_;
	if ( $self->{'cgi'}->param('function') eq 'examples' ) {
		$self->{'type'} = 'text';
	} else {
		$self->{'jQuery'} = 1;
	}
}

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( $q->param('function') eq 'examples' ) {
		$self->_print_examples;
		return;
	}
	my $scheme_id = $q->param('scheme_id');
	if ( !BIGSdb::Utils::is_int($scheme_id) ) {
		$scheme_id = -1;
	}
	if ( $self->{'system'}->{'dbtype'} ne 'sequences' ) {
		print "<h1>Batch profile query</h1>\n";
		print "<div class=\"box\" id=\"statusbad\"><p>This function is only available for sequence definition databases.</p></div>\n";
		return;
	}
	my $scheme_info = $self->{'datastore'}->get_scheme_info($scheme_id) if $scheme_id > 0;
	if ( ( !$scheme_info->{'id'} || !$scheme_id ) ) {
		print "<h1>Batch profile query</h1>\n";
		print "<div class=\"box\" id=\"statusbad\"><p>Invalid scheme selected.</p></div>\n";
		return;
	}

	$" = ', ';
	my $loci =
	  $self->{'datastore'}->run_list_query( "SELECT locus FROM scheme_members WHERE scheme_id=? ORDER BY field_order", $scheme_id );
	my @cleaned_loci;
	foreach (@$loci){
		my $cleaned = $_;
		my $locus_info = $self->{'datastore'}->get_locus_info($_);
		$cleaned .= " ($locus_info->{'common_name'})" if $locus_info->{'common_name'};
		$cleaned =~ tr/_/ /;
		push @cleaned_loci,$cleaned;
	}
	print "<h1>Batch profile query - $scheme_info->{'description'}</h1>\n";
	if ( $q->param('profiles') ) {
		my $profiles = $q->param('profiles');
		my @rows     = split /\n/, $profiles;
		$"='</th><th>';
		print 
"<div class=\"box\" id=\"resultstable\"><table class=\"resultstable\"><tr><th>Isolate</th><th>@cleaned_loci</th>\n";
		my $scheme_fields = $self->{'datastore'}->get_scheme_fields($scheme_id);
		foreach (@$scheme_fields){
			my $cleaned = $_;
			$cleaned =~ tr/_/ /;
			print "<th>$cleaned</th>\n";
		}
		$"=',';
		my $qry = "SELECT @$scheme_fields FROM scheme_$scheme_id WHERE ";
		$"='=? AND ';
		my @cleaned_loci = @$loci;
		foreach (@cleaned_loci){
			$_ =~ s/'/_PRIME_/g;
		}
		$qry .= "@cleaned_loci=?";
		my $sql = $self->{'db'}->prepare($qry);
		print "</tr>\n";
		my $td = 1;
		$"='</td><td>';
		$| = 1;
		foreach (@rows){
			my @profile = split/\t/;
			my $isolate = shift @profile;
			foreach (@profile){
				$_=~s/^\s+//g;
				$_=~s/\s+$//g;
			}
			print "<tr class=\"td$td\"><td>$isolate</td>";
			for (my $i = 0; $i< @$loci; $i++){
				if ( $profile[$i]){
					print "<td>$profile[$i]</td>";
				} else {
					print "<td class=\"statusbad\" style=\"font-size:2em\">-</td>";
				}
			}
			my $incomplete;
			my @field_data;
			if (@profile >= @$loci){
				while (@profile > @$loci){
					pop @profile;
				}			
				eval {
					$sql->execute(@profile);
				};
				if ($@){
					$logger->error("Can't execute $@");
				}
				@field_data = $sql->fetchrow_array;
			} else {
				$incomplete =1 ;
			}
			my $i=0;
			foreach (@$scheme_fields){
				if (exists $field_data[$i]){
					print "<td>$field_data[$i]</td>";
				} else {
					print "<td class=\"statusbad\" style=\"font-size:2em\">-</td>";
				}
				$i++;
			}
			print "</tr>\n";
			$td = $td == 1 ? 2 : 1;
			if ( $ENV{'MOD_PERL'} ) {
				$self->{'mod_perl_request'}->rflush;
				return if $self->{'mod_perl_request'}->connection->aborted;
			}
		}
		print "</table>\n</div>\n";
		return;
	}
	
		
	print "<div class=\"box\" id=\"queryform\">\n";
	print $q->start_form;
	foreach (qw (db page scheme_id)) {
		print $q->hidden($_);
	}
	
	
	print <<"HTML";
<p>Enter allelic profiles below in tab (or space) delimited text format 
using copy and paste (for example directly from a spreadsheet).  
Columns can be separated by any amount of whitespace.  The first column 
should be an isolate identifier and the remaining columns should comprise 
the allele numbers (order: @cleaned_loci), click here for 
<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=batchProfiles&amp;function=examples&amp;scheme_id=$scheme_id">example data</a>.  
Non-numerical characters will be stripped out of the query.</p>
HTML
	print $q->textarea( -name => 'profiles', -rows => 10, -columns => 80, -override => 1 );
	print "<p />";
	print $q->reset( -class => 'reset' );
	print $q->submit( -label => 'Submit query', -class => 'submit' );
	print $q->endform;
	print "<p />";
	print "</div>";
}

sub _print_examples {

	#Generate example data file for batch profile query
	#Get up to 15 random profiles from the database
	my ($self)    = @_;
	my $q         = $self->{'cgi'};
	my $scheme_id = $q->param('scheme_id');
	if ( !BIGSdb::Utils::is_int($scheme_id) ) {
		$scheme_id = -1;
	}
	if ( $self->{'system'}->{'dbtype'} ne 'sequences' ) {
		print "This function is only available for sequence definition databases.\n";
		return;
	}
	my $scheme_info = $self->{'datastore'}->get_scheme_info($scheme_id) if $scheme_id > 0;
	if ( ( !$scheme_info->{'id'} || !$scheme_id ) ) {
		print "Invalid scheme selected.\n";
		return;
	}
	my @ids;
	my $loci =
	  $self->{'datastore'}->run_list_query( "SELECT locus FROM scheme_members WHERE scheme_id=? ORDER BY field_order", $scheme_id );
	$"   = ',';
	my @cleaned_loci = @$loci;
	foreach (@cleaned_loci){
		$_ =~ s/'/_PRIME_/g;
	}
	my $sql = $self->{'db'}->prepare("SELECT @cleaned_loci FROM scheme_$scheme_id ORDER BY random() LIMIT 15");
	eval { $sql->execute; };
	if ($@) {
		$logger->error("Can't execute $@");
	}
	$" = "\t";
	my $i = 1;
	while ( my @profile = $sql->fetchrow_array ) {
		print "isolate_$i\t@profile\n";
		$i++;
	}
}
1;
