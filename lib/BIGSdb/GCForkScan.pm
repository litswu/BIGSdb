#Written by Keith Jolley
#Copyright (c) 2017, University of Oxford
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
package BIGSdb::GCForkScan;
use Parallel::ForkManager;
use BIGSdb::GCHelper;
use Log::Log4perl qw(get_logger :nowarn);
use strict;
use warnings;
use 5.010;

sub new {
	my ( $class, $params ) = @_;
	my $self = {};
	$self->{'jobManager'}       = $params->{'jobManager'};
	$self->{'config_dir'}       = $params->{'config_dir'};
	$self->{'lib_dir'}          = $params->{'lib_dir'};
	$self->{'dbase_config_dir'} = $params->{'dbase_config_dir'};
	$self->{'logger'}           = $params->{'logger'};
	$self->{'config'}           = $params->{'config'};
	bless( $self, $class );
	return $self;
}

sub run {
	my ( $self, $params ) = @_;
	my $by_ref = $params->{'reference_file'} ? 1 : 0;
	if ( $params->{'threads'} && $params->{'threads'} > 1 ) {
		my $script;
		$script = BIGSdb::GCHelper->new(    #Create script object to use methods to determine isolate list
			{
				config_dir       => $self->{'config_dir'},
				lib_dir          => $self->{'lib_dir'},
				dbase_config_dir => $self->{'dbase_config_dir'},
				logger           => $self->{'logger'},
				options          => { query_only => 1, always_run => 1, %$params },
				instance         => $params->{'database'},
				params           => $params->{'user_params'}
			}
		);
		my $loci = $script->get_selected_loci;
		if ( !@$loci ) {
			$self->{'logger'}->error('No valid loci selected.');
			return;
		}
		my $isolates        = $script->get_isolates;
		my $data            = {};
		my $new_seqs        = {};
		my $pm              = Parallel::ForkManager->new( $params->{'threads'} );
		my $isolate_count   = 0;
		my $finish_progress = $params->{'align'} ? 20 : 80;
		$pm->run_on_finish(
			sub {
				my ( $pid, $exit_code, $ident, $exit_signal, $core_dump, $ret_data ) = @_;
				$data->{$_} = $ret_data->{'designations'}->{$_} foreach keys %{ $ret_data->{'designations'} };
				$new_seqs->{ $ret_data->{'isolate_id'} }->{$_} = $ret_data->{'local_new_seqs'}->{$_}
				  foreach keys %{ $ret_data->{'local_new_seqs'} };
				$isolate_count++;
				if ( $params->{'job_id'} ) {
					my $percent_complete = int( ( $isolate_count * $finish_progress ) / @$isolates );
					$self->{'jobManager'}->update_job_status(
						$params->{'job_id'},
						{
							percent_complete => $percent_complete,
							stage            => "Scanning: isolate record $isolate_count complete"
						}
					);
				}
			}
		);
		foreach my $isolate_id (@$isolates) {
			last if $self->_is_job_cancelled( $params->{'job_id'} );
			$pm->start and next;
			my $helper = BIGSdb::GCHelper->new(
				{
					config_dir       => $self->{'config_dir'},
					lib_dir          => $self->{'lib_dir'},
					dbase_config_dir => $self->{'dbase_config_dir'},
					logger           => $self->{'logger'},
					options          => { i => $isolate_id, always_run => 1, fast => 1, %$params },
					instance         => $params->{'database'},
					params           => $params->{'user_params'},
					locus_data       => $params->{'locus_data'}
				}
			);
			my $isolate_data   = $helper->get_results;
			my $local_new_seqs = $helper->get_new_sequences;
			$pm->finish( 0,
				{ designations => $isolate_data, local_new_seqs => $local_new_seqs, isolate_id => $isolate_id } );
			undef $helper;
		}
		$pm->wait_all_children;
		$self->_correct_new_designations( $data, $new_seqs, $by_ref );
		return $data;
	}

	#Run non-threaded job
	my $helper = BIGSdb::GCHelper->new(
		{
			config_dir       => $self->{'config_dir'},
			lib_dir          => $self->{'lib_dir'},
			dbase_config_dir => $self->{'dbase_config_dir'},
			logger           => $self->{'logger'},
			options          => { always_run => 1, fast => 1, global_new => 1, %$params },
			instance         => $params->{'database'},
			user_params      => $params->{'user_params'},
			locus_data       => $params->{'locus_data'}
		}
	);
	my $batch_data = $helper->get_results;
	my $new_seqs   = $helper->get_new_sequences;
	if ($by_ref) {
		$self->_rename_ref_designations_from_single_thread($batch_data);
	}
	return $batch_data;
}

sub _is_job_cancelled {
	my ( $self, $job_id ) = @_;
	my $signal_file = "$self->{'config'}->{'secure_tmp_dir'}/${job_id}.CANCEL";
	return 1 if -e $signal_file;
	return;
}

sub _correct_new_designations {
	my ( $self, $data, $new_seqs, $by_ref ) = @_;
	my @isolates;
	my %loci;
	foreach my $isolate_id ( sort { $a <=> $b } keys %$new_seqs ) {
		push @isolates, $isolate_id;
		foreach my $locus ( sort { $a cmp $b } keys %{ $new_seqs->{$isolate_id}->{'allele_lookup'} } ) {
			$loci{$locus} = 1;
		}
	}
	my @loci = sort keys %loci;
	foreach my $locus (@loci) {
		my $i = 1;
		my %hash_names;
		foreach my $isolate_id (@isolates) {
			foreach my $md5_hash ( keys %{ $new_seqs->{$isolate_id}->{'allele_lookup'}->{$locus} } ) {
				if ( !$hash_names{$md5_hash} ) {
					$hash_names{$md5_hash} = $by_ref ? ( $i + 1 ) : "new#$i";
					$i++;
				}
				$data->{$isolate_id}->{'designations'}->{$locus} = $hash_names{$md5_hash};
			}
		}
	}
	return;
}

sub _rename_ref_designations_from_single_thread {
	my ( $self, $data ) = @_;
	foreach my $isolate_id ( keys %$data ) {
		foreach my $locus ( keys %{$data->{$isolate_id}->{'designations'}} ) {
			$data->{$isolate_id}->{'designations'}->{$locus} =~ s/^new#//x;
		}
	}
	return;
}
1;
