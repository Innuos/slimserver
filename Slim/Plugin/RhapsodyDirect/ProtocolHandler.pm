package Slim::Plugin::RhapsodyDirect::ProtocolHandler;

# $Id: ProtocolHandler.pm 11678 2007-03-27 14:39:22Z andy $

# Rhapsody Direct handler for rhapd:// URLs.

use strict;
use warnings;

use HTML::Entities qw(encode_entities);
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(decode_base64);
use Net::IP;
use Scalar::Util qw(blessed);

use Slim::Plugin::RhapsodyDirect::RPDS;
use Slim::Networking::SqueezeNetwork;
use Slim::Utils::Cache;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use constant SN_DEBUG => 0;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.rhapsodydirect',
	'defaultLevel' => $ENV{RHAPSODY_DEV} ? 'DEBUG' : 'ERROR',
	'description'  => 'PLUGIN_RHAPSODY_DIRECT_MODULE_NAME',
});

my $prefs = preferences('server');

sub isRemote { 1 }

sub getFormatForURL { 'mp3' }

sub canSeek {
	my ( $class, $client ) = @_;
	
	# XXX: temporary, will be SN-only after firmware is released
	my $canSeek = 0;
	
	my $deviceid = $client->deviceid;
	my $rev      = $client->revision;
	
	if ( $deviceid == 4 && $rev >= 113 ) {
		$canSeek = 1;
	}
	elsif ( $deviceid == 5 && $rev >= 63 ) {
		$canSeek = 1;
	}
	elsif ( $deviceid == 7 && $rev >= 48 ) {
		$canSeek = 1;
	}
	elsif ( $deviceid == 10 && $rev >= 33 ) {
		$canSeek = 1;
	}
	
	return $canSeek;
}

# Source for AudioScrobbler
sub audioScrobblerSource {
	my ( $class, $client, $url ) = @_;

	if ( $url =~ /\.rdr$/ ) {
		# R = Non-personalised broadcast
		return 'R';
	}

	# P = Chosen by the user
	return 'P';
}

sub parseDirectHeaders {
	my ( $class, $client, $url, @headers ) = @_;
	
	my $length;
	my $rangelength;
	
	# Clear previous duration, since we're using the same URL for all tracks
	if ( $url =~ /\.rdr$/ ) {
		Slim::Music::Info::setDuration( $url, 0 );
	}

	foreach my $header (@headers) {

		$log->debug("RhapsodyDirect header: $header");

		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
		}
		elsif ( $header =~ m{^Content-Range: .+/(.*)}i ) {
			$rangelength = $1;
		}
	}
	
	if ( $rangelength ) {
		$length = $rangelength;
	}
	
	# Save length for reinit and seeking
	$client->pluginData( length => $length );

	# ($title, $bitrate, $metaint, $redir, $contentType, $length, $body)
	return (undef, 192000, 0, '', 'mp3', $length, undef);
}

# Don't allow looping
sub shouldLoop { 0 }

sub isRepeatingStream {
	my (undef, $song) = @_;
	
	return $song->{'track'}->url =~ /\.rdr$/;
}

sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;
	
	# Don't allow pause on radio
	if ( $action eq 'pause' && $url =~ /\.rdr$/ ) {
		return 0;
	}
	
	return 1;
}

sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;
	
	$log->debug("Direct stream failed: [$response] $status_line\n");
	
	if ( main::SLIM_SERVICE && SN_DEBUG ) {
		SDI::Service::EventLog->log(
			$client, 'rhapsody_error', "$response - $status_line"
		);
	}
	
	$client->controller()->playerStreamingFailed($client, 'PLUGIN_RHAPSODY_DIRECT_STREAM_FAILED');
}

sub _handleClientError {
	my ($error, $client, $params) = @_;
	
	my $song    = $params->{'song'};
	
	return if $song->pluginData('abandonSong');
	
	# Tell other clients to give up
	$song->pluginData(abandonSong => 1);
	
	$params->{'errorCb'}->($error);
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $client = $song->master();
	my $url    = $song->{'track'}->url;
	
	$song->pluginData( radioTrackURL => undef );
	$song->pluginData( radioTitle    => undef );
	$song->pluginData( radioTrack    => undef );
	$song->pluginData( abandonSong   => 0 );
	
	if (_tooManySynced($client)) {
		$errorCb->('PLUGIN_RHAPSODY_DIRECT_TOO_MANY_SYNCED');
		return;
	}
	
	my $params = {
		song      => $song,
		url       => $url,
		successCb => $successCb,
		errorCb   => $errorCb,
	};
	
	# 0. If playing Rhapsody, log track-played (handled via onDecode callback)
	
	# 1. If this is a radio-station then get next track info
	if ($class->isRepeatingStream($song)) {
		_getNextRadioTrack($params);
	} else {
		_getTrack($params);
	}
	
	# 2. For each player in sync-group:
	
	# 2.1 Get account if necessary 
	# 2.2 Get playback-session if necessary (if playingSong != Rhapsody)
	# 2.3 Get mediaURL (rpds 3)

}

# Only allow 3 players synced, throw an error if more are synced
sub _tooManySynced {
	my $client = shift;
	
	my @clients =  $client->syncGroupActiveMembers();
	
	return unless @clients > 1;
	
	my $tooMany  = 0;
	my %accounts = ();

	if ( my $account = _getAccount($client) ) {
		for my $client ( @clients ) {
			if ( $account->{defaults} ) {
				if ( my $default = $account->{defaults}->{ $client->id } ) {
					$accounts{ $default } ||= 0;
					$accounts{ $default }++;
				}
				else {
					$accounts{ $account->{username}->[0] } ||= 0;
					$accounts{ $account->{username}->[0] }++;
				}
			}
			else {
				$accounts{ $account->{username}->[0] } ||= 0;
				$accounts{ $account->{username}->[0] }++;
			}
		}
	}
	
	# If any one account has more than 3 players on it, sync will fail
	$tooMany = grep { $_ > 3 } values %accounts;
	
	return $tooMany;
}

sub _getAccount {
	my $client= shift;
	
	# Always pull account info directly from the database on SN
	if ( main::SLIM_SERVICE ) {
		my @username = $prefs->client($client)->get('plugin_rhapsody_direct_username');
		my @password = $prefs->client($client)->get('plugin_rhapsody_direct_password');
		my $defaults = {};
		
		if ( scalar @username > 1 ) {
			if ( my $default = $prefs->client($client)->get('plugin_rhapsody_direct_account') ) {
				$defaults->{ $client->id } = $default;
			}
		}
		
		my $clientType = 'squeezebox3.logitech';
		my $deviceid   = $client->deviceid;
		
		if ( $deviceid == 5 ) {
			$clientType = 'transporter.logitech';
		}
		elsif ( $deviceid == 7 ) {
			$clientType = 'receiver.logitech';
		}
		elsif ( $deviceid == 10 ) {
			$clientType = 'boom.logitech';
		}
		elsif ( $deviceid == 9 ) {
			$clientType = 'squeezeplay.logitech';
		}
		
		my $account = {
			username   => \@username,
			password   => \@password,
			defaults   => $defaults,
			cobrandId  => 40134,
			clientType => $clientType,
		};
		
		return $account;
	}
	
	my $account = $client->pluginData('account');
	
	return $account;
}

sub _getCurrentUser {
	my $client = shift;
	
	my $account = _getAccount($client);
	
	# Choose the correct account to use for this player's session
	my $username = $account->{username}->[0];
	
	if ( $account->{defaults} ) {
		if ( my $default = $account->{defaults}->{ $client->id } ) {
			
			my $i = 0;
			for my $user ( @{ $account->{username} } ) {
				if ( $default eq $user ) {
					$username = $account->{username}->[ $i ];
					last;
				}
				$i++;
			}
		}
	}
	
	return $username;
}

# 1. If this is a radio-station then get next track info
sub _getNextRadioTrack {
	my ($params) = @_;
		
	my ($stationId) = $params->{'url'} =~ m{rhapd://(.+)\.rdr};
	
	# Talk to SN and get the next track to play
	my $radioURL = Slim::Networking::SqueezeNetwork->url(
		"/api/rhapsody/v1/radio/getNextTrack?stationId=$stationId"
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		\&_gotNextRadioTrack,
		\&_gotNextRadioTrackError,
		{
			client => $params->{'song'}->master(),
			params => $params,
		},
	);
	
	$log->debug("Getting next radio track from SqueezeNetwork");
	
	$http->get( $radioURL );
}

# 1.1a If this is a radio-station then get next track info
sub _gotNextRadioTrack {
	my $http   = shift;
	my $client = $http->params->{client};
	my $params = $http->params->{params};
	my $song   = $params->{'song'};
	my $url    = $song->{'track'}->url;
	
	my $track = eval { from_json( $http->content ) };
	
	if ( $log->is_debug ) {
		$log->debug( 'Got next radio track: ' . Data::Dump::dump($track) );
	}
	
	if ( $track->{error} ) {
		# We didn't get the next track to play
		
		my $error = ( $client->isPlaying(1) && $client->playingSong()->{'track'}->url =~ /\.rdr/ )
					? 'PLUGIN_RHAPSODY_DIRECT_NO_NEXT_TRACK'
					: 'PLUGIN_RHAPSODY_DIRECT_NO_TRACK';
		
		$params->{'errorCb'}->($error, $url);

		# Set the title after the errro callback so the current title
		# is still the radio-station name during the callback
		Slim::Music::Info::setCurrentTitle( $url, $client->string('PLUGIN_RHAPSODY_DIRECT_NO_TRACK') );
			
		return;
	}
	
	# set metadata for track, will be set on playlist newsong callback
	$url      = 'rhapd://' . $track->{trackId} . '.mp3';
	my $title = $track->{name} . ' ' . 
			$client->string('BY') . ' ' . $track->{displayArtistName} . ' ' . 
			$client->string('FROM') . ' ' . $track->{displayAlbumName};
	
	$song->pluginData( radioTrackURL => $url );
	$song->pluginData( radioTitle    => $title );
	$song->pluginData( radioTrack    => $track );
	
	# We already have the metadata for this track, so can save calling getTrack
	my $meta = {
		artist    => $track->{displayArtistName},
		album     => $track->{displayAlbumName},
		title     => $track->{name},
		cover     => $track->{cover},
		bitrate   => '192k CBR',
		type      => 'MP3 (Rhapsody)',
		info_link => 'plugins/rhapsodydirect/trackinfo.html',
		icon      => Slim::Plugin::RhapsodyDirect::Plugin->_pluginDataFor('icon'),
		buttons   => {
			# disable REW/Previous button in radio mode
			rew => 0,
		},
	};
	
	my $cache = Slim::Utils::Cache->new;
	$cache->set( 'rhapsody_meta_' . $track->{trackId}, $meta, 86400 );
	
	$params->{'url'} = $url;
	_getTrack($params);
}

# 1.1b If this is a radio-station then get next track info
sub _gotNextRadioTrackError {
	my $http   = shift;
	my $client = $http->params('client');
	
	_handleClientError( $http->error, $client, $http->params->{params} );
}

# 2. For each player in sync-group: get accounrt, session, track-info as necessary
sub _getTrack {
	my $params  = shift;
	
	my $song    = $params->{'song'};
	my @players = $song->master()->syncGroupActiveMembers();
	
	$song->pluginData(playersNotReady => scalar @players);
	
	my $playingSong = $song->master()->playingSong();
	my $needNewSession = 1;
	
	# We can skip getting a new session if we were just playing another Rhapsody track
	if (   $playingSong 
		&& $playingSong->currentTrackHandler eq __PACKAGE__
	) {
		$needNewSession = 0;
	}
	
	for my $client (@players) {
		_getTrackByClient($client, $params, $needNewSession);
	}
}

# 2.1 Get account if necessary 
# 2.2 Get playback-session if necessary (if playingSong != Rhapsody)
sub _getTrackByClient {
	my $client     = shift;
	my $params     = shift;
	my $getSession = shift;
	
	if ( main::SLIM_SERVICE ) {
		# Fail if firmware doesn't support mp3
		my $old;
		
		my $deviceid = $client->deviceid;
		my $rev      = $client->revision;
		
		if ( $deviceid == 4 && $rev < 97 ) {
			$old = 1;
		}
		elsif ( $deviceid == 5 && $rev < 45 ) {
			$old = 1;
		}
		elsif ( $deviceid == 7 && $rev < 32 ) {
			$old = 1;
		}
		
		if ( $old ) {
			handleError( $client->string('PLUGIN_RHAPSODY_DIRECT_FIRMWARE_UPGRADE_REQUIRED'), $client );
			return;
		}
	}
	
	# Get login info from SN if we don't already have it
	my $account = _getAccount($client);
	
	if ( !$account ) {
		my $accountURL = Slim::Networking::SqueezeNetwork->url( '/api/rhapsody/v1/account' );
		
		my $http = Slim::Networking::SqueezeNetwork->new(
			\&gotAccount,
			\&gotAccountError,
			{
				client => $client,
				cb     => sub {
					return if $params->{'song'}->pluginData('abandonSong');
					_getTrackByClient( $client, $params, $getSession );
				},
				ecb    => sub {
					my $error = shift;
					return if $params->{'song'}->pluginData('abandonSong');
					$error = $client->string('PLUGIN_RHAPSODY_DIRECT_ERROR_ACCOUNT') . ": $error";
					_handleClientError( $error, $client, $params );
				},
			},
		);
		
		$log->debug("Getting Rhapsody account from SqueezeNetwork");
		
		$http->get( $accountURL );
		
		return;
	}
	
	if ( $getSession ) {
		
		if ( !$params->{_sentip} ) {
			# Lookup the correct address for secure-direct and inform the players
			# The firmware has a hardcoded address but it may change
			my $dns = Slim::Networking::Async->new;
			$dns->open( {
				Host    => 'secure-direct.rhapsody.com',
				onDNS   => sub {
					my $ip = shift;

					$log->debug( "Found IP for secure-direct.rhapsody.com: $ip" );

					$ip = Net::IP->new($ip);

					rpds( $client, {
						data        => pack( 'cNn', 0, $ip->intip, 443 ),
						_noresponse => 1,
					} );

					$params->{_sentip} = 1;

					_getTrackByClient( $client, $params, $getSession );
				},
				onError => sub {
					_handleClientError( $client->string('PLUGIN_RHAPSODY_DIRECT_DNS_ERROR'), $client, $params );
				},
			} );

			return;
		}
		
		$log->debug("Ending any previous playback session");

		# Clear any previous outstanding rpds queries
		cancel_rpds($client);

		rpds( $client, {
			data        => pack( 'c', 6 ),
			callback    => \&_getPlaybackSession,
			onError     => sub {
				_getPlaybackSession( $client, undef, $params );
			},
			passthrough => [ $params ],
		} );
		
		return;
	}

	_getTrackInfo($client, undef, $params);
}

# 2.1a Get account if necessary
sub gotAccount {
	my $http  = shift;
	my $params = $http->params;
	my $client = $params->{client};
	
	my $account = eval { from_json( $http->content ) };
	
	if ( ref $account eq 'HASH' ) {
		$client->pluginData( account => $account );
		
		if ( $log->is_debug ) {
			$log->debug( "Got Rhapsody account info from SN" );
		}
		
		$params->{cb}->();
	}
	else {
		$params->{ecb}->($@);
	}
}

# 2.1b Get account if necessary
sub gotAccountError {
	my $http   = shift;
	my $params = $http->params;
	
	$params->{ecb}->( $http->error );
}

# 2.2 Get playback-session if necessary (if playingSong != Rhapsody)
sub _getPlaybackSession {
	my ( $client, undef, $params ) = @_;
	
	# Always get a new playback session
	if ( $log->is_debug ) {
		$log->debug( $client->id, ' Requesting new playback session...');
	}
	
	# Get login info
	my $account = _getAccount($client);
	
	# Choose the correct account to use for this player's session
	my $username = $account->{username}->[0];
	my $password = $account->{password}->[0];
	
	if ( $account->{defaults} ) {
		if ( my $default = $account->{defaults}->{ $client->id } ) {
			$log->debug( $client->id, " Using default account $default" );
			
			my $i = 0;
			for my $user ( @{ $account->{username} } ) {
				if ( $default eq $user ) {
					$username = $account->{username}->[ $i ];
					$password = $account->{password}->[ $i ];
					last;
				}
				$i++;
			}
		}
	}
	
	my $packet = pack 'cC/a*C/a*C/a*C/a*', 
		2,
		encode_entities( $username ),
		$account->{cobrandId}, 
		encode_entities( decode_base64( $password ) ), 
		$account->{clientType};
	
	# When synced, all players will make this request to get a new playback session
	
	rpds( $client, {
		data        => $packet,
		callback    => \&_getTrackInfo,
		onError     => \&_handleClientError,
		passthrough => [ $params ],
	} );
}

# 2.3 Get mediaURL (rpds 3)
sub _getTrackInfo {
    my ( $client, undef, $params ) = @_;

	my $song    = $params->{'song'};
	
	return if $song->pluginData('abandonSong');

	# Get track URL for the next track
	my ($trackId) = $params->{'url'} =~ m{rhapd://(.+)\.mp3};
	
	rpds( $client, {
		data        => pack( 'cC/a*', 3, $trackId ),
		callback    => \&_gotTrackInfo,
		onError     => \&_gotTrackError,
		passthrough => [ $params ],
	} );
}

# 2.3a Get mediaURL 
sub _gotTrackInfo {
	my ( $client, $mediaUrl, $params ) = @_;
	
    my $song = $params->{'song'};
    
    return if $song->pluginData('abandonSong');
    
	(undef, $mediaUrl) = unpack 'cn/a*', $mediaUrl;
	
	# Save the media URL for use in strm
	$song->pluginData( mediaUrl => $mediaUrl );
	
	my $playersNotReady = $song->pluginData('playersNotReady') - 1;
    $song->pluginData('playersNotReady' => $playersNotReady);
    
    return if $playersNotReady > 0;
	
	# When synced, the below code is run for only the last player to reach here
	
	# Async resolve the hostname so gethostbyname in Player::Squeezebox::stream doesn't block
	# When done, callback will continue on to playback
	my $dns = Slim::Networking::Async->new;
	$dns->open( {
		Host        => URI->new($mediaUrl)->host,
		Timeout     => 3, # Default timeout of 10 is too long, 
		                  # by the time it fails player will underrun and stop
		onDNS       => $params->{'successCb'},
		onError     => $params->{'successCb'}, # even if it errors, keep going
		passthrough => [],
	} );
	
	# Watch for playlist commands
	Slim::Control::Request::subscribe( 
		\&_playlistCallback, 
		[['playlist'], ['newsong']],
		$song->master(),
	);
}

# 2.3b Get mediaURL 
sub _gotTrackError {
	my ( $error, $client, $params ) = @_;
	
	$log->debug("Error during getTrackInfo: $error");

	return if $params->{'song'}->pluginData('abandonSong');
    
	if ( main::SLIM_SERVICE ) {
		SDI::Service::EventLog->log(
			$client, 'rhapsody_track_error', $error
		);
	}

	_handleClientError( $error, $client, $params );
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	
	my $icon = $class->getIcon();
	
	if ( $url =~ /\.rdr$/ ) {
		my $song = $client->currentSongForUrl($url);
		if (!$song || !($url = $song->pluginData('radioTrackURL'))) {
			return {
				bitrate   => '192k CBR',
				type      => 'MP3 (Rhapsody)',
				icon      => $icon,
				cover     => $icon,
			};
		}
	}
	
	return {} unless $url;
	
	my $cache = Slim::Utils::Cache->new;
	
	# If metadata is not here, fetch it so the next poll will include the data
	my ($trackId) = $url =~ m{rhapd://(.+)\.mp3};
	my $meta      = $cache->get( 'rhapsody_meta_' . $trackId );
	
	if ( !$meta && !$client->pluginData('fetchingMeta') ) {
		# Go fetch metadata for all tracks on the playlist without metadata
		my @need;
		
		for my $track ( @{ $client->playlist } ) {
			my $trackURL = blessed($track) ? $track->url : $track;
			if ( $trackURL =~ m{rhapd://(.+)\.mp3} ) {
				my $id = $1;
				if ( !$cache->get("rhapsody_meta_$id") ) {
					push @need, $id;
				}
			}
		}
		
		if ( $log->is_debug ) {
			$log->debug( "Need to fetch metadata for: " . join( ', ', @need ) );
		}
		
		$client->pluginData( fetchingMeta => 1 );
		
		my $metaUrl = Slim::Networking::SqueezeNetwork->url(
			"/api/rhapsody/v1/playback/getBulkMetadata"
		);
		
		my $http = Slim::Networking::SqueezeNetwork->new(
			\&_gotBulkMetadata,
			\&_gotBulkMetadataError,
			{
				client  => $client,
				timeout => 60,
			},
		);

		$http->post(
			$metaUrl,
			'Content-Type' => 'application/x-www-form-urlencoded',
			'trackIds=' . join( ',', @need ),
		);
	}
	
	#$log->debug( "Returning metadata for: $url" . ($meta ? '' : ': default') );
	
	return $meta || {
		bitrate   => '192k CBR',
		type      => 'MP3 (Rhapsody)',
		icon      => $icon,
		cover     => $icon,
	};
}

sub _gotBulkMetadata {
	my $http   = shift;
	my $client = $http->params->{client};
	
	$client->pluginData( fetchingMeta => 0 );
	
	my $info = eval { from_json( $http->content ) };
	
	if ( $@ || ref $info ne 'ARRAY' ) {
		$log->error( "Error fetching track metadata: " . ( $@ || 'Invalid JSON response' ) );
		return;
	}
	
	if ( $log->is_debug ) {
		$log->debug( "Caching metadata for " . scalar( @{$info} ) . " tracks" );
	}
	
	# Cache metadata
	my $cache = Slim::Utils::Cache->new;
	my $icon  = Slim::Plugin::RhapsodyDirect::Plugin->_pluginDataFor('icon');

	for my $track ( @{$info} ) {
		next unless ref $track eq 'HASH';
		
		# cache the metadata we need for display
		my $trackId = delete $track->{trackId};
		
		my $meta = {
			%{$track},
			bitrate   => '192k CBR',
			type      => 'MP3 (Rhapsody)',
			info_link => 'plugins/rhapsodydirect/trackinfo.html',
			icon      => $icon,
		};
	
		$cache->set( 'rhapsody_meta_' . $trackId, $meta, 86400 );
	}
	
	# Update the playlist time so the web will refresh, etc
	$client->currentPlaylistUpdateTime( Time::HiRes::time() );
}

sub _gotBulkMetadataError {
	my $http   = shift;
	my $client = $http->params('client');
	my $error  = $http->error;
	
	$log->warn("Error getting track metadata from SN: $error");
}

sub _playlistCallback {
	my $request = shift;
	my $client  = $request->client();
	my $p1      = $request->getRequest(1);
	
	return unless defined $client;
	
	# check that user is still using Rhapsody Radio
	my $song = $client->playingSong();
	
	if ( !$song || $song->currentTrackHandler ne __PACKAGE__ ) {
		# User stopped playing Rhapsody, 

		$log->debug( "Stopped Rhapsody, unsubscribing from playlistCallback" );
		Slim::Control::Request::unsubscribe( \&_playlistCallback, $client );
		
		# XXX maybe end session
		
		return;
	}
	
	if ( $song->pluginData('radioTrackURL') && $p1 eq 'newsong' ) {
		# A new song has started playing.  We use this to change titles
		
		my $title = $song->pluginData('radioTitle');
		
		$log->debug("Setting title for radio station to $title");
		
		Slim::Music::Info::setCurrentTitle( $song->{'track'}->url, $title );
	}
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;
	
	my $mediaUrl = $song->pluginData('mediaUrl');

	return $mediaUrl || 0;
}

sub stopCallback {
	my $request = shift;
	my $client  = $request->client();
	my $p0      = $request->getRequest(0);
	my $p1      = $request->getRequest(1) || '';
	
	return unless defined $client;
	
	# Handle 'stop' and 'playlist clear'
	if ( $p0 eq 'stop' || $p1 eq 'clear' ) {

		# Check that the user is still playing Rhapsody
		my $url = Slim::Player::Playlist::url($client) || $client->pluginData('lastURL');

		if ( !$url || $url !~ /^rhapd/ ) {
			# stop listening for stop events
			$log->debug("No longer playing Rhapsody, ignoring (URL: $url)");
			Slim::Control::Request::unsubscribe( \&stopCallback, $client );
			return;
		}
		
		# Ignore if a new track is already starting
		if ( $client->pluginData('trackStarting') ) {
			$log->debug("Player stopped ($p0 $p1) but another track was already starting, ignoring");
			return;
		}
		
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			SDI::Service::EventLog->log(
				$client, 'rhapsody_stop'
			);
		}

		my $songtime = Slim::Player::Source::songTime($client);
		
		if ( $songtime > 0 ) {	
			if ($log->is_debug) {
				$log->debug("Player stopped ($p0 $p1), logging usage info ($songtime seconds)...");
			}
			
			# There are different log methods for normal vs. radio play
			my $data;

			if ( my ($stationId) = $url =~ m{rhapd://(.+)\.rdr} ) {
				# logMeteringInfoForStationTrackPlay
				$data = pack( 'cC/a*C/a*', 5, $songtime, $stationId );
			}
			else {
				# logMeteringInfo
				$data = pack( 'cC/a*', 4, $songtime );
			}
			
			my @clients = $client->syncGroupActiveMembers();
			
			for my $eachClient ( @clients ) {
				rpds( $eachClient, {
					data        => $data,
					callback    => \&endPlaybackSession,
					onError     => sub {
						# We don't really care if the logging call fails,
						# so allow onError to work like the normal callback
						endPlaybackSession( $eachClient	 );
					},
					passthrough => [],
				} );
			}
		}
		else {
			if ($log->is_debug) {
				$log->debug("Player stopped ($p0 $p1) but songtime was $songtime, ignoring");
			}
		}
	}
}

sub endPlaybackSession {
	my $client = shift;
	
	rpds( $client, {
		data        => pack( 'c', 6 ),
		callback    => sub {},
		onError     => sub {},
		passthrough => [],
	} );
}

# URL used for CLI trackinfo queries
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;
	
	my $stationId;
	
	if ( $url =~ m{rhapd://(.+)\.rdr} ) {
		my $song = $client->currentSongForUrl($url);
		
		# Radio mode, pull track ID from lastURL
		$url = $song->pluginData('radioTrackURL');
		$stationId = $1;
	}

	my ($trackId) = $url =~ m{rhapd://(.+)\.mp3};
	
	# SN URL to fetch track info menu
	my $trackInfoURL = Slim::Networking::SqueezeNetwork->url(
		'/api/rhapsody/v1/opml/metadata/getTrack?trackId=' . $trackId
	);
	
	if ( $stationId ) {
		$trackInfoURL .= '&stationId=' . $stationId;
	}
	
	return $trackInfoURL;
}

# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;
	
	my $url          = $track->url;
	my $trackInfoURL = $class->trackInfoURL( $client, $url );
	
	# let XMLBrowser handle all our display
	my %params = (
		header   => 'PLUGIN_RHAPSODY_DIRECT_GETTING_TRACK_DETAILS',
		modeName => 'Rhapsody Now Playing',
		title    => Slim::Music::Info::getCurrentTitle( $client, $url ),
		url      => $trackInfoURL,
	);
	
	$log->debug( "Getting track information for $url" );

	Slim::Buttons::Common::pushMode( $client, 'xmlbrowser', \%params );
	
	$client->modeParam( 'handledTransition', 1 );
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Slim::Plugin::RhapsodyDirect::Plugin->_pluginDataFor('icon');
}

sub onStop {
	my ($class, $song) = @_;
	
	_doLog(Slim::Player::Source::songTime($song->master()), $song);
}

sub onPlayout {
	my ($class, $song) = @_;
	
	_doLog($song->duration(), $song);
}

sub _doLog {
	my ($time, $song) = @_;
	
	$time = int($time);
	
	$log->debug("Log metering: $time");
	
	# There are different log methods for normal vs. radio play
	my $stationId;
	my $trackId;

	if ( ($stationId) = $song->{track}->url =~ m{rhapd://(.+)\.rdr} ) {
		# logMeteringInfoForStationTrackPlay
		$song = $song->master()->currentSongForUrl( $song->{track}->url );
		
		my $url = $song->pluginData('radioTrackURL');
		
		($trackId) = $url =~ m{rhapd://(.+)\.mp3};		
	}
	else {
		# logMeteringInfo
		$stationId = '';
		($trackId) = $song->{track}->url =~ m{rhapd://(.+)\.mp3};
	}
	
	my $logURL = Slim::Networking::SqueezeNetwork->url(
		"/api/rhapsody/v1/playback/log?stationId=$stationId&trackId=$trackId&playtime=$time"
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		sub {
			if ( $log->is_debug ) {
				my $http = shift;
				$log->debug( "Logging returned: " . $http->content );
			}
		},
		sub {},
		{
			client => $song->master(),
		},
	);
	
	$log->debug("Logging track playback: $time seconds, trackId: $trackId, stationId: $stationId");
	
	$http->get( $logURL );
}


sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;
	
	# Determine byte offset and song length in bytes
	my $meta    = $class->getMetadataFor( $client, $song->{track}->url );
	
	my $bitrate =  192;
	my $duration = $meta->{duration} || return;
	
	# Calculate the RAD and EA offsets for this time offset
	my $percent   = $newtime / $duration;
	my $radlength = $client->pluginData('length') - 36;
	my $nb        = 1 + int($radlength / 3072);
	my $ealength  = 36 + (24 * $nb);
	my $radoffset = ( int($nb * $percent) * 3072 ) + 36;
	my $eaoffset  = ( int($nb * $percent) * 24 ) + 36;
	
	# Send special seek information
	for my $c ( $client->syncGroupActiveMembers() ) {
		rpds( $c, {
			data        => pack( 'cNN', 7, $eaoffset, $ealength ),
			_noresponse => 1,
		} );
	}
		
	return {
		sourceStreamOffset => $radoffset,
		timeOffset         => $newtime,
	};
}

# SN only, re-init upon reconnection
# XXX: new-streaming fixes
sub reinit {
	my ( $class, $client, $playlist, $currentSong ) = @_;
	
	$log->debug('Re-init Rhapsody');
	
	SDI::Service::EventLog->log(
		$client, 'rhapsody_reconnect'
	);
	
	# If in radio mode, re-add only the single item
	if ( scalar @{$playlist} == 1 && $playlist->[0] =~ /\.rdr$/ ) {
		$client->execute([ 'playlist', 'add', $playlist->[0] ]);
	}
	else {	
		# Re-add all playlist items
		$client->execute([ 'playlist', 'addtracks', 'listref', $playlist ]);
	}
	
	# Make sure we are subscribed to stop/playlist commands
	# Watch for stop commands for logging purposes
	Slim::Control::Request::subscribe( 
		\&stopCallback, 
		[['stop', 'playlist']],
		$client,
	);
	
	# Reset song duration/progress bar
	my $currentURL = $playlist->[ $currentSong ];
	
	if ( my $length = $client->pluginData('length') ) {			
		# On a timer because $client->currentsongqueue does not exist yet
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time(),
			sub {
				my $client = shift;
				
				$client->streamingProgressBar( {
					url     => $currentURL,
					length  => $length,
					bitrate => 128000,
				} );
				
				# If it's a radio station, reset the title
				if ( my ($stationId) = $currentURL =~ m{rhapd://(.+)\.rdr} ) {
					my $title = $client->pluginData('radioTitle');

					$log->debug("Resetting title for radio station to $title");

					Slim::Music::Info::setCurrentTitle( $currentURL, $title );
				}
				
				# Back to Now Playing
				# This is within the timer because otherwise it will run before
				# addtracks adds all the tracks, and not jump to the correct playing item
				Slim::Buttons::Common::pushMode( $client, 'playlist' );
			},
		);
	}
}

1;
