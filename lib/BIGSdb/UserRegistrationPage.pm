#Written by Keith Jolley
#Copyright (c) 2016, University of Oxford
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
package BIGSdb::UserRegistrationPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::CuratePage BIGSdb::ChangePasswordPage);
use BIGSdb::Constants qw(:accounts :interface);
use Mail::Sender;
use Email::Valid;
use Digest::MD5;
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');

sub print_content {
	my ($self) = @_;
	say q(<h1>Account registration</h1>);
	if ( !$self->{'config'}->{'auto_registration'} ) {
		say q(<div class="box" id="statusbad"><p>This site does not allow automated registrations.</p></div>);
		return;
	}
	if ( $self->{'system'}->{'dbtype'} ne 'user' ) {
		say q(<div class="box" id="statusbad"><p>Account registrations can not be performed )
		  . q(when accessing a database.<p></div>);
		return;
	}
	my $q = $self->{'cgi'};
	if ( $q->param('register') ) {
		$self->_register;
		return;
	}
	$self->_print_registration_form;
	return;
}

sub _print_registration_form {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	say q(<div class="box queryform">);

	#TODO Change icon to fa-id-card-o after upgrading font awesome
	say q(<span class="main_icon fa fa-user fa-3x pull-left"></span>);
	say q(<h2>Register</h2>);
	say q(<p>If you don't already have a site account, you can register below. Please ensure that you enter a valid )
	  . q(E-mail address as account validation details will be sent to this.</p>);
	say q(<p>Please note that user names:</p><ul>);
	say q(<li>should be between 4 and 20 characters long</li>);
	say q(<li>can contain only alpha-numeric characters (A-Z, a-z, 0-9) - no spaces, hyphens or punctuation</li>);
	say q(<li>are case-sensitive</li>);
	say q(</ul>);
	say $q->start_form;
	say q(<fieldset class="form" style="float:left"><legend>Please enter your details</legend>);
	say q(<ul><li>);
	my $user_dbs = $self->{'config'}->{'site_user_dbs'};
	my $values   = [];
	my $labels   = {};

	foreach my $user_db (@$user_dbs) {
		push @$values, $user_db->{'dbase'};
		$labels->{ $user_db->{'dbase'} } = $user_db->{'name'};
	}
	say q(<label for="db" class="form">Domain: </label>);
	if ( @$values == 1 ) {
		say $q->popup_menu(
			-name     => 'domain',
			-id       => 'domain',
			-values   => $values,
			-labels   => $labels,
			-disabled => 'disabled'
		);
		say $q->hidden( domain => $values->[0] );
	} else {
		unshift @$values, q();
		say $q->popup_menu(
			-name     => 'domain',
			-id       => 'domain',
			-values   => $values,
			-labels   => $labels,
			-required => 'required'
		);
	}
	say q(</li><li>);
	say q(<label for="user_name" class="form">User name:</label>);
	say $q->textfield( -name => 'user_name', -id => 'user_name', -required => 'required', size => 25 );
	say q(</li><li>);
	say q(<label for="first_name" class="form">First name:</label>);
	say $q->textfield( -name => 'first_name', -id => 'first_name', -required => 'required', size => 25 );
	say q(</li><li>);
	say q(<label for="surname" class="form">Last name/surname:</label>);
	say $q->textfield( -name => 'surname', -id => 'surname', -required => 'required', size => 25 );
	say q(</li><li>);
	say q(<label for="email" class="form">E-mail:</label>);
	say $q->textfield( -name => 'email', -id => 'email', -required => 'required', size => 25 );
	say q(</li><li>);
	say q(<label for="affiliation" class="form">Affiliation (institute):</label>);
	say $q->textarea( -name => 'affiliation', -id => 'affiliation', -required => 'required' );
	say q(</li></ul>);
	say q(</fieldset>);
	$q->param( register => 1 );
	say $q->hidden($_) foreach qw(page register);
	$self->print_action_fieldset( { no_reset => 1 } );
	say $q->end_form;
	say q(</div>);
	return;
}

sub _register {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	foreach my $param (qw(domain first_name surname email affiliation)) {
		if ( !$q->param($param) ) {
			say q(<div class="box" id="statusbad"><p>Please complete form.</p></div>);
			$self->_print_registration_form;
			return;
		}
	}
	my $data = {};
	$data->{$_} = $q->param($_) foreach qw(domain user_name first_name surname email affiliation);
	if ( $self->_bad_username( $data->{'user_name'} ) || $self->_bad_email( $data->{'email'} ) ) {
		$self->_print_registration_form;
		return;
	}
	$self->format_data( 'users', $data );
	$data->{'password'} = $self->_create_password;
	eval {
		$self->{'db'}->do(
			'INSERT INTO users (user_name,first_name,surname,email,affiliation,date_entered,'
			  . 'datestamp,status,validate_start) VALUES (?,?,?,?,?,?,?,?,?)',
			undef,
			$data->{'user_name'},
			$data->{'first_name'},
			$data->{'surname'},
			$data->{'email'},
			$data->{'affiliation'},
			'now',
			'now',
			'pending',
			time
		);
		$self->set_password_hash(
			$data->{'user_name'},
			Digest::MD5::md5_hex( $data->{'password'} . $data->{'user_name'} ),
			{ reset_password => 1 }
		);
	};
	if ($@) {
		say q(<div class="box" id="statusbad"><p>User creation failed. This error has been logged - )
		  . q(please try again later.</p></div>);
		$logger->error($@);
		$self->{'db'}->rollback;
		return;
	}
	$self->{'db'}->commit;
	$self->_send_email($data);
	say q(<div class="box" id="resultspanel">);

	#TODO Change icon to fa-id-card-o after upgrading font awesome
	say q(<span class="main_icon fa fa-user fa-3x pull-left"></span>);
	say q(<h2>New account</h2>);
	say q(<p>A new account has been created with the details below. The user name and a randomly-generated )
	  . q(password has been sent to your E-mail address. You are required to validate your account by )
	  . qq(logging in and changing your password within $self->{'validate_time'} minutes.</p>);
	say q(<dl class="data">);
	say qq(<dt>First name</dt><dd>$data->{'first_name'}</dd>);
	say qq(<dt>Last name</dt><dd>$data->{'surname'}</dd>);
	say qq(<dt>E-mail</dt><dd>$data->{'email'}</dd>);
	say qq(<dt>Affiliation</dt><dd>$data->{'affiliation'}</dd>);
	say q(</dl>);
	say q(<dl class="data">);
	say qq(<dt>Username</dt><dd><b>$data->{'user_name'}</b></dd>);
	say q(</dl>);
	say qq(<p>Please note that your account may be removed if you do not log in for $self->{'inactive_time'} days. )
	  . q(This does not apply to accounts that have submitted data linked to them within the database.</p>);
	say q(<p>Once you log in you will be able to register for specific resources on the site.</p>);
	my $class = RESET_BUTTON_CLASS;
	say qq(<p><a href="$self->{'system'}->{'script_name'}" class="$class ui-button-text-only"><span class="ui-button-text">Log in</span></a></p>);
	say q(</div>);
	return;
}

sub _bad_email {
	my ( $self, $email ) = @_;
	my $address = Email::Valid->address($email);
	if ( !$address ) {
		say q(<div class="box" id="statusbad"><p>The provided E-mail address is not valid.</p></div>);
		return 1;
	}
	return;
}

sub _bad_username {
	my ( $self, $user_name ) = @_;
	my @problems;
	my $length = length $user_name;
	if ( $length > 20 || $length < 4 ) {
		my $plural = $length == 1 ? q() : q(s);
		push @problems, qq(Username must be between 4 and 20 characters long - your is $length character$plural long.);
	}
	if ( $user_name =~ /[^A-Za-z0-9]/x ) {
		push @problems, q(Username contains non-alphanumeric (A-Z, a-z, 0-9) characters.);
	}
	my $invalid =
	  $self->{'datastore'}->run_query( 'SELECT user_name FROM invalid_usernames UNION SELECT user_name FROM users',
		undef, { fetch => 'col_arrayref' } );
	my %invalid = map { $_ => 1 } @$invalid;
	if ( $invalid{$user_name} ) {
		push @problems, q(Username is aready registered. Site-wide accounts cannot use a user name )
		  . q(that is currently in use in any databases on the site.);
	}
	if (@problems) {
		local $" = q(<br />);
		say qq(<div class="box" id="statusbad"><p>@problems</p></div>);
		return 1;
	}
	return;
}

sub _send_email {
	my ( $self, $data ) = @_;
	if ( !$self->{'config'}->{'smtp_server'} ) {
		$logger->error('Cannot send E-mail - smtp_server is not set in bigsdb.conf.');
		return;
	}
	my $args = { smtp => $self->{'config'}->{'smtp_server'}, to => $data->{'email'}, from => $data->{'email'} };
	my $mail_sender = Mail::Sender->new($args);
	my $message =
	    qq(An account has been set up for you on $self->{'config'}->{'domain'}\n\n)
	  . qq(Please log in with the following details in the next $self->{'validate_time'} minutes. The account )
	  . qq(will be removed if you do not log in within this time - if this happens you will need to re-register.\n\n)
	  . qq(You will be required to change your password when you first log in.\n\n)
	  . qq(Username: $data->{'user_name'}\n)
	  . qq(Password: $data->{'password'}\n);
	$mail_sender->MailMsg(
		{
			subject => "New $self->{'config'}->{'domain'} user account",
			ctype   => 'text/plain',
			charset => 'utf-8',
			msg     => $message
		}
	);
	no warnings 'once';
	$logger->error($Mail::Sender::Error) if $mail_sender->{'error'};
	return;
}

sub _create_password {
	my ($self) = @_;

	#Avoid ambiguous characters (I, l, 1, O, 0)
	my @allowed_chars = qw(
	  A B C D E F G H J K L M N P Q R S T U V W X Y Z
	  a b c d e f g h j k m n p q r s t u v w x y z
	  1 2 3 4 5 6 7 8 9
	);
	my $password;
	$password .= @allowed_chars[ rand( scalar @allowed_chars ) ] foreach ( 1 .. 12 );
	return $password;
}

sub get_title {
	return 'User registration';
}

sub initiate {
	my ($self) = @_;
	$self->{$_} = 1 foreach qw(jQuery noCache);
	$self->{'validate_time'} =
	  BIGSdb::Utils::is_int( $self->{'config'}->{'new_account_validation_timeout_mins'} )
	  ? $self->{'config'}->{'new_account_validation_timeout_mins'}
	  : NEW_ACCOUNT_VALIDATION_TIMEOUT_MINS;
	$self->{'inactive_time'} =
	  BIGSdb::Utils::is_int( $self->{'config'}->{'inactive_account_removal_days'} )
	  ? $self->{'config'}->{'inactive_account_removal_days'}
	  : INACTIVE_ACCOUNT_REMOVAL_DAYS;
	return if !$self->{'config'}->{'site_user_dbs'};
	my $q = $self->{'cgi'};
	if ( $q->param('domain') ) {
		$self->{'system'}->{'db'} = $q->param('domain');
		$self->use_correct_user_database;
	}
	return;
}
1;