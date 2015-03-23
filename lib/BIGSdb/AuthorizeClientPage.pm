#Written by Keith Jolley
#Copyright (c) 2015, University of Oxford
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
package BIGSdb::AuthorizeClientPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::Page);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');
use constant REQUEST_TOKEN_EXPIRES => 3600;

sub initiate {
	my ($self) = @_;
	$self->{$_} = 1 foreach qw (jQuery noCache);
	return;
}

sub print_content {
	my ($self)   = @_;
	my $q        = $self->{'cgi'};
	my $token_id = $q->param('oauth_token');
	say "<h1>Authorize client software to access your account</h1>";
	if ( $self->{'system'}->{'authentication'} ne 'builtin' ) {
		say qq(<div class="box" id="statusbad"><p>This database does not use built-in authentication.  You cannot )
		  . qq(currently authorize third-party applications.</p></div>);
		return;
	} elsif ( !$token_id ) {
		say qq(<div class="box" id="statusbad"><p>No request token specified.</p></div>);
		return;
	}
	my $token =
	  $self->{'datastore'}
	  ->run_query( "SELECT * FROM request_tokens WHERE token=?", $token_id, { db => $self->{'auth_db'}, fetch => 'row_hashref' } );
	if ( !$token ) {
		say qq(<div class="box" id="statusbad"><p>Invalid token submitted.  It is possible that the token has expired.</p></div>);
		return;
	} elsif ( time - $token->{'start_time'} > REQUEST_TOKEN_EXPIRES ) {
		say qq(<div class="box" id="statusbad"><p>The request token has expired.</p></div>);
		return;
	} elsif ( $token->{'verifier'} ) {
		say qq(<div class="box" id="statusbad"><p>The request token has already been redeemed.</p></div>);
		return;
	}
	my $client =
	  $self->{'datastore'}
	  ->run_query( "SELECT * FROM clients WHERE client_id=?", $token->{'client_id'}, { db => $self->{'auth_db'}, fetch => 'row_hashref' } );
	if ( !$client ) {
		say qq(<div class="box" id="statusbad"><p>The client is not recognized.</p></div>);
		$logger->error("Client $token->{'client_id'} does not exist.  This should not be possible.");    #Token is linked to client
		return;
	} elsif ( !$self->_can_client_access_database( $token->{'client_id'}, $client->{'default_permission'}, $self->{'system'}->{'db'} ) ) {
		say qq(<div class="box" id="statusbad"><p>The client does not have permission to access this resource.</p></div>);
		return;
	}
	if ( $q->param('submit') ) {
		$self->_authorize_token($client);
		return;
	}
	say qq(<div class="box" id="queryform"><div class="scrollable"><p>Do you wish for the following application to access data on your )
	  . qq(behalf?</p>);
	say qq(<fieldset style="float:left"><legend>Application</legend>);
	say qq(<p><b>$client->{'application'} );
	say qq(version $client->{'version'}) if $client->{'version'};
	say qq(</b></p></fieldset>);
	my $desc = $self->{'system'}->{'description'};
	if ($desc) {
		say qq(<fieldset style="float:left"><legend>Resource</legend>);
		say qq(<b>$desc</b>);
		say qq(</fieldset>);
	}
	say $q->start_form;
	$self->print_action_fieldset( { submit_label => 'Authorize', reset_label => 'Cancel', page => 'index' } );
	say $q->hidden($_) foreach qw(db page oauth_token);
	say $q->end_form;
	say qq(<p>You will be able to revoke access for this application at any time.</p>);

	#TODO Add revocation information.
	say qq(</div></div>);
	return;
}

sub _authorize_token {
	my ( $self, $client ) = @_;
	my $q        = $self->{'cgi'};
	my $verifier = BIGSdb::Utils::random_string(8);
	eval {
		$self->{'auth_db'}->do(
			"UPDATE request_tokens SET (username,dbase,verifier,start_time)=(?,?,?,?) WHERE token=?",
			undef, $self->{'username'}, $self->{'system'}->{'db'},
			$verifier, time, $q->param('oauth_token')
		);
	};
	if ($@) {
		say qq(<div class="box" id="statusbad"><p>Token could not be authorized.</p></div>);
		$logger->error($@);
		$self->{'auth_db'}->rollback;
	} else {
		say qq(<div class="box" id="resultspanel">);
		my $version = $client->{'version'} ? " version $client->{'version'} " : '';
		my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
		say qq(<p>You have authorized <b>$client->{'application'}$version</b> to access <b>$desc</b> on your behalf.</p>);
		say qq(<p>Enter the following verification code when asked by $client->{'application'}.</p>);
		say qq(<p><b>Verification code: $verifier</b></p>);
		say qq(<p>This code is valid for ) . ( REQUEST_TOKEN_EXPIRES / 60 ) . qq( minutes.</p>);

		#TODO Add revocation information.
		say qq(</div>);
		$self->{'auth_db'}->commit;
	}
	return;
}

sub _can_client_access_database {
	my ( $self, $client_id, $default_permission, $dbase ) = @_;
	my $authorize = $self->{'datastore'}->run_query(
		"SELECT authorize FROM client_permissions WHERE (client_id,dbase)=(?,?)",
		[ $client_id, $dbase ],
		{ db => $self->{'auth_db'} }
	);
	if ( $default_permission eq 'allow' ) {
		return ( !$authorize || $authorize eq 'allow' ) ? 1 : 0;
	} else {    #default deny
		return ( !$authorize || $authorize eq 'deny' ) ? 0 : 1;
	}
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return "Authorize third-party client - $desc";
}
1;