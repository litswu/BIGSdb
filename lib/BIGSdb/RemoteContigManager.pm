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
package BIGSdb::RemoteContigManager;
use strict;
use warnings;
use 5.010;
use BIGSdb::BIGSException;
use LWP::UserAgent;
use HTTP::Request::Common;
use Net::OAuth 0.20;
$Net::OAuth::PROTOCOL_VERSION = Net::OAuth::PROTOCOL_VERSION_1_0A;
use JSON;
use Data::Random qw(rand_chars);
use Digest::MD5;
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Application_Authentication');

sub new {
	my ( $class, @atr ) = @_;
	my $self = {@atr};
	bless( $self, $class );
	$self->{'ua'} = LWP::UserAgent->new( agent => 'BIGSdb' );
	$logger->info('Remote contig manager set up.');
	return $self;
}

#Faster method to retrieve multiple contigs without extended metadata.
#This checks the isolate URI from the first retrieved contig and if it
#contains a URI to contigs_fasta will download all contigs in one call.
sub get_remote_contigs_by_list {
	my ( $self, $uri_list ) = @_;
	my $contigs = {};
	return $contigs if !@$uri_list;
	my %batch_seqs;
	while (@$uri_list) {
		my $uri = shift @$uri_list;
		( my $contig_route = $uri ) =~ s/\/\d+$//x;
		if ( $batch_seqs{$uri} ) {
			$contigs->{$uri} = $batch_seqs{$uri};
			next;
		}
		my $contig = $self->get_remote_contig($uri);
		if ( $contig->{'sequence'} ) {
			$contigs->{$uri} = $contig->{'sequence'};
			if ( $contig->{'isolate_id'} ) {
				my $isolate_record = $self->get_remote_isolate( $contig->{'isolate_id'} );
				if ( $isolate_record->{'sequence_bin'}->{'contigs_fasta'} ) {
					my $fasta = $self->get_remote_fasta( $isolate_record->{'sequence_bin'}->{'contigs_fasta'} );
					eval {
						my $seqs = BIGSdb::Utils::read_fasta( \$fasta );
						foreach my $seqbin_id ( keys %$seqs ) {
							my $contig_uri = "$contig_route/$seqbin_id";
							$batch_seqs{$contig_uri} = $seqs->{$seqbin_id};
						}
					};
					$logger->error($@) if $@;
				}
			}
		}
	}
	return $contigs;
}

sub update_remote_contig_length {
	my ( $self, $uri, $length ) = @_;
	eval { $self->{'db'}->do( 'UPDATE remote_contigs SET length=? WHERE uri=?', undef, $length, $uri ); };
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub update_isolate_remote_contig_lengths {
	my ( $self, $isolate_id ) = @_;
	my $qry = 'SELECT r.uri,r.length FROM sequence_bin s JOIN remote_contigs r ON '
	  . 's.id=r.seqbin_id WHERE s.isolate_id=? AND remote_contig';
	my $remote_contigs = $self->{'datastore'}->run_query( $qry, $isolate_id,
		{ fetch => 'all_arrayref', slice => {}, cache => 'RemoteContigManager::update_isolate_remote_contig_lengths' }
	);
	my $uri_list = [];
	foreach my $contig (@$remote_contigs) {
		next if $contig->{'length'};
		push @$uri_list, $contig->{'uri'};
	}
	return if !@$uri_list;
	
	my $contigs = $self->get_remote_contigs_by_list($uri_list);
	foreach my $contig (@$remote_contigs) {
		$self->update_remote_contig_length( $contig->{'uri'}, length( $contigs->{ $contig->{'uri'} } ) );
	}
	return;
}

sub get_remote_contig {
	my ( $self, $uri, $options ) = @_;
	( my $base_uri = $uri ) =~ s/\/contigs\/\d+$//x;
	if ( $uri !~ /\?/x ) {
		$uri .= q(?no_loci=1);
	}
	my $contig = $self->_get_remote_record( $base_uri, $uri );
	my $length = length $contig->{'sequence'};
	if ( $options->{'length'} ) {
		if ( $length != $options->{'length'} ) {
			$logger->error("Contig $uri length has changed!");
		}
	}
	my $checksum = Digest::MD5::md5_hex( $contig->{'sequence'} );
	if ( $options->{'checksum'} ) {
		if ( $checksum ne $options->{'checksum'} ) {
			$logger->error("Contig $uri checksum has changed!");
		}
	}
	if ( $options->{'set_checksum'} && $options->{'seqbin_id'} ) {
		eval {
			$self->{'db'}
			  ->do( 'UPDATE remote_contigs SET (length,checksum)=(?,?) WHERE uri=?', undef, $length, $checksum, $uri );
			$self->{'db'}->do(
				'UPDATE sequence_bin SET (method,original_designation,comments)=(?,?,?) WHERE id=?',
				undef, $contig->{'method'}, $contig->{'original_designation'},
				$contig->{'comments'}, $options->{'seqbin_id'}
			);
		};
		if ($@) {
			$logger->error($@);
			$self->{'db'}->rollback;
		} else {
			$self->{'db'}->commit;
		}
	}
	return $contig;
}

sub get_remote_contig_list {
	my ( $self, $uri ) = @_;
	( my $base_uri = $uri ) =~ s/\/isolates\/\d+\/contigs[\?return_all=1]*$//x;
	return $self->_get_remote_record( $base_uri, $uri );
}

sub get_remote_isolate {
	my ( $self, $uri ) = @_;
	( my $base_uri = $uri ) =~ s/\/isolates\/\d+$//x;
	return $self->_get_remote_record( $base_uri, $uri );
}

sub get_remote_fasta {
	my ( $self, $uri ) = @_;
	( my $base_uri = $uri ) =~ s/\/isolates\/\d+\/contigs_fasta$//x;
	return $self->_get_remote_record( $base_uri, $uri, { non_json => 1 } );
}

sub _get_remote_record {
	my ( $self, $base_uri, $uri, $options ) = @_;
	my $oauth_credentials = $self->{'datastore'}->run_query( 'SELECT * FROM oauth_credentials WHERE base_uri=?',
		$base_uri, { fetch => 'row_hashref', cache => 'RemoteContigManager::get_credentials' } );
	my $requires_authorization = $oauth_credentials ? 1 : 0;
	if ( !$requires_authorization ) {
		my $response = $self->{'ua'}->get($uri);
		if ( $response->is_success ) {
			if ( $options->{'non_json'} ) {
				return $response->decoded_content;
			}
			my $data;
			eval { $data = decode_json( $response->decoded_content ); };
			throw BIGSdb::DataException('Data is not JSON') if $@;
			return $data;
		} else {
			if ( $response->code == 401 ) {
				$requires_authorization = 1;
			}
		}
	}
	if ($requires_authorization) {
		if ( !$oauth_credentials ) {
			throw BIGSdb::AuthenticationException("$uri requires authorization - no credentials set");
		}
		return $self->_get_protected_route( $oauth_credentials, $base_uri, $uri, $options );
	}
	throw BIGSdb::FileException("Cannot retrieve $uri");
}

sub _get_protected_route {
	my ( $self, $oauth_credentials, $base_uri, $uri, $options ) = @_;
	if ( !$oauth_credentials->{'session_token'} ) {
		$self->_get_session_token( $oauth_credentials, $base_uri );
	}
	my $request = Net::OAuth->request('protected resource')->new(
		consumer_key     => $oauth_credentials->{'consumer_key'},
		consumer_secret  => $oauth_credentials->{'consumer_secret'},
		token            => $oauth_credentials->{'session_token'},
		token_secret     => $oauth_credentials->{'session_secret'},
		request_url      => $uri,
		request_method   => 'GET',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => join( '', rand_chars( size => 16, set => 'alphanumeric' ) ),
	);
	$request->sign;
	throw BIGSdb::AuthenticationException('Cannot verify signature') unless $request->verify;
	my $res = $self->{'ua'}->get( $request->to_url );
	if ( $options->{'non_json'} ) {
		return $res->content;
	}
	my $decoded_json;
	eval { $decoded_json = decode_json( $res->content ) };
	if ($@) {
		$logger->error( $res->content );
		return;
	}
	throw BIGSdb::DataException('Invalid JSON') if ref $decoded_json ne 'HASH';
	if ( ( $decoded_json->{'message'} // q() ) =~ /Client\ is\ unauthorized/x ) {
		throw BIGSdb::AuthenticationException('Access denied - client is unauthorized.');
	}
	if ( ( $decoded_json->{'status'} // q() ) eq '401' ) {
		$logger->info('Invalid session token, requesting new one.');
		$self->_remove_session_token($base_uri);
		$self->_get_session_token( $oauth_credentials, $base_uri );
		return $self->_get_protected_route( $oauth_credentials, $base_uri, $uri );
	}
	return $decoded_json;
}

sub _remove_session_token {
	my ( $self, $base_uri ) = @_;
	eval {
		$self->{'db'}->do( 'UPDATE oauth_credentials SET session_token=NULL,session_secret=NULL WHERE base_uri=?',
			undef, $base_uri );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub _get_session_token {
	my ( $self, $oauth_credentials, $base_uri ) = @_;
	my $request = Net::OAuth->request('protected resource')->new(
		consumer_key     => $oauth_credentials->{'consumer_key'},
		consumer_secret  => $oauth_credentials->{'consumer_secret'},
		token            => $oauth_credentials->{'access_token'},
		token_secret     => $oauth_credentials->{'access_secret'},
		request_url      => "$base_uri/oauth/get_session_token",
		request_method   => 'GET',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => join( '', rand_chars( size => 16, set => 'alphanumeric' ) ),
	);
	$request->sign;
	throw BIGSdb::AuthenticationException('Cannot verify signature') unless $request->verify;
	my $res = $self->{'ua'}->request( GET $request->to_url, Content_Type => 'application/json' );
	my $decoded_json = decode_json( $res->content );
	if ( $res->is_success ) {
		my $session_response = Net::OAuth->response('access token')->from_hash($decoded_json);
		eval {
			$self->{'db'}->do( 'UPDATE oauth_credentials SET (session_token,session_secret)=(?,?) WHERE base_uri=?',
				undef, $session_response->token, $session_response->token_secret, $base_uri );
		};
		if ($@) {
			$logger->error($@);
			$self->{'db'}->rollback;
		} else {
			$self->{'db'}->commit;
		}
		$oauth_credentials->{'session_token'}  = $session_response->token;
		$oauth_credentials->{'session_secret'} = $session_response->token_secret;
		return $session_response;
	} else {
		throw BIGSdb::AuthenticationException("Invalid access token for $base_uri");
	}
}
1;