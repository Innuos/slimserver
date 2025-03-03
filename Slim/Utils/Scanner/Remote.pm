package Slim::Utils::Scanner::Remote;

#
# Logitech Media Server Copyright 2001-2020 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, version 2.

=head1 NAME

Slim::Utils::Scanner::Remote

=head1 SYNOPSIS

Slim::Utils::Scanner::Remote->scanURL( $url, {
	client => $client,
	cb     => sub { ... },
} );

=head1 DESCRIPTION

This class handles anything to do with obtaining information about a remote
music source, whether that is a playlist, mp3 stream, wma stream, remote mp3 file with
ID3 tags, etc.

=head1 METHODS

=cut

# TODO
# Build a submenu of TrackInfo to select alternate streams in remote playlists?
# Duplicate playlist items sometimes get into the DB, maybe when multiple nested playlists
#   refer to the same stream (Q-91.3 http://opml.radiotime.com/StationPlaylist.axd?stationId=22200)
# Ogg broken: http://opml.radiotime.com/StationPlaylist.axd?stationId=54657

use strict;

use Audio::Scan;
use File::Temp ();
use HTTP::Request;
use IO::String;
use Scalar::Util qw(blessed);

use Slim::Formats;
use Slim::Formats::Playlists;
use Slim::Networking::Async::HTTP;
use Slim::Player::Protocols::MMS;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $log = logger('scan.scanner');

use constant MAX_DEPTH => 7;

my %ogg_quality = (
	0  => 64000,
	1  => 80000,
	2  => 96000,
	3  => 112000,
	4  => 128000,
	5  => 160000,
	6  => 192000,
	7  => 224000,
	8  => 256000,
	9  => 320000,
	10 => 500000,
);


=head2 parseRemoteHeader( $track, $url, $format, $successCb, $errorCb );

parse a remote URL to acquire header and populate $track object. When
finished, calls back success or error callback

=cut

my %parsers = (
	'wma' => { parser => \&parseWMAHeader, readLimit => 128 * 1024 },
	'aac' => { parser => \&parseAACHeader, readLimit => 4 * 1024 },
	'ogg' => { parser => \&parseOggHeader, readLimit => 64 },
	'flc' => { parser => \&parseFlacHeader },
	'wav' => { parser => \&parseWavAifHeader, extra => 'format' },
	'aif' => { parser => \&parseWavAifHeader, extra => 'format' },
	'mp4' => { parser => \&parseMp4Header, extra => 'url' },
	'mp3' => { parser => \&parseAudioStream, extra => 'url' },
);

sub parseRemoteHeader {
	my ($track, $url, $format, $successCb, $errorCb) = @_;

	# first, tidy up things a bit
	$url ||= $track->url;
	$format =~ s/flac/flc/;

	my $parser = $parsers{$format};
	return $successCb->() unless $parser;

	my $http = Slim::Networking::Async::HTTP->new;
	my $method = $parser->{'readLimit'} ? 'onBody' : 'onStream';
	push my @extra, $url if $parser->{'extra'} =~ /url/;
	push @extra, $format if $parser->{'extra'} =~ /format/;

	$http->send_request( {
		request     => HTTP::Request->new( GET => $url ),
		$method     => $parser->{'parser'},
		readLimit   => $parser->{'readLimit'},
		onError     => $errorCb,
		passthrough => [ $track, { cb => $successCb }, @extra ],
	} );
}

=head2 scanURL( $url, $args );

Scan a remote URL.  When finished, calls back to $args->{cb} with a success flag
and an error string if the scan failed.

=cut

sub scanURL {
	my ( $class, $url, $args ) = @_;

	my $client = $args->{client};
	my $cb     = $args->{cb} || sub {};
	my $pt     = $args->{pt} || [];

	$args->{depth} ||= 0;

	main::DEBUGLOG && $log->is_debug && $log->debug( "Scanning remote stream $url" );

	if ( !$url ) {
		return $cb->( undef, 'SCANNER_REMOTE_NO_URL_PROVIDED', @{$pt} );
	}

	if ( !Slim::Music::Info::isRemoteURL($url) ) {
		return $cb->( undef, 'SCANNER_REMOTE_INVALID_URL', @{$pt} );
	}

	# Refuse to scan too deep in a nested playlist
	if ( $args->{depth} >= MAX_DEPTH ) {
		return $cb->( undef, 'SCANNER_REMOTE_NESTED_TOO_DEEP', @{$pt} );
	}

	# Get/Create a track object for this URL
	my $track = Slim::Schema->updateOrCreate( {
		url => $url,
	} );

	# Make sure it has a title
	if ( !$track->title ) {
		$args->{'title'} ||= $args->{'song'}->track->title if $args->{'song'};
		$track = Slim::Music::Info::setTitle( $url, $args->{'title'} ? $args->{'title'} : $url );
	}

	# Check if the protocol handler has a custom scanning method
	# This is used to allow plugins to add scanning routines for exteral stream types
	my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
	if ($handler && $handler->can('scanStream') ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( "Scanning remote stream $url using protocol hander $handler" );

		# Allow protocol hander to scan the stream and then call the callback
		$handler->scanStream($url, $track, $args);

		return;
	}

	# In some cases, a remote protocol may always be audio and not need scanning
	# This is not used by any core code, but some plugins require it
	my $isAudio = Slim::Music::Info::isAudioURL($url);

	$url =~ s/#slim:.+$//;

	if ( $isAudio ) {
		main::DEBUGLOG && $log->is_debug && $log->debug( "Remote stream $url known to be audio" );

		# Set this track's content type from protocol handler getFormatForURL method
		my $type = Slim::Music::Info::typeFromPath($url);
		if ( $type eq 'unk' ) {
			$type = 'mp3';
		}

		main::DEBUGLOG && $log->is_debug && $log->debug( "Content-type of $url - $type" );

		$track->content_type( $type );
		$track->update;

		# Success, done scanning
		return $cb->( $track, undef, @{$pt} );
	}

	# Bug 4522, if user has disabled native WMA decoding to get MMS support, don't scan MMS URLs
	if ( $url =~ /^mms/i ) {

		# XXX This test will not be good enough when we get WMA proxied streaming
		if ( main::TRANSCODING && ! Slim::Player::TranscodingHelper::isEnabled('wma-wma-*-*') ) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Not scanning MMS URL because direct streaming disabled.');

			$track->content_type( 'wma' );

			return $cb->( $track, undef, @{$pt} );
		}
	}

	# Connect to the remote URL and figure out what it is
	my $request = HTTP::Request->new( GET => $url );

	main::DEBUGLOG && $log->is_debug && $log->debug("Scanning remote URL $url");

	# Use WMP headers for MMS protocol URLs or ASF/ASX/WMA URLs
	if ( $url =~ /(?:^mms|\.asf|\.asx|\.wma)/i ) {
		addWMAHeaders( $request );
	}

	my $timeout = preferences('server')->get('remotestreamtimeout');

	my $send = sub {
		my $http = Slim::Networking::Async::HTTP->new;
		$http->send_request( {
			request     => $request,
			onRedirect  => \&handleRedirect,
			onHeaders   => \&readRemoteHeaders,
			onError     => sub {
				my ( $http, $error ) = @_;

				logError("Can't connect to remote server to retrieve playlist for, ", $request->uri, ": $error.");

				$track->error( $error );

				return $cb->( undef, $error, @{$pt} );
			},
			passthrough => [ $track, $args ],
			Timeout     => $timeout,
		} );
	};

	if ( $args->{delay} ) {
		Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + $args->{delay}, $send );
	}
	else {
		$send->();
	}
}

=head2 addWMAHeaders( $request )

Adds Windows Media Player headers to the HTTP request to make it a valid 'Describe' request.
See Microsoft HTTP streaming spec for details:
http://msdn2.microsoft.com/en-us/library/cc251059.aspx

=cut

sub addWMAHeaders {
	my $request = shift;

	my $url = $request->uri->as_string;
	$url =~ s/^mms/http/;

	$request->uri( $url );

	my $h = $request->headers;
	$h->header( 'User-Agent' => 'NSPlayer/8.0.0.3802' );
	$h->header( Pragma => [
		'xClientGUID={' . Slim::Player::Protocols::MMS::randomGUID(). '}',
		'no-cache',
	] );
	$h->header( Connection => 'close' );
}

=head2 handleRedirect( $http, $track, $args )

Callback when Async::HTTP encounters a redirect.  If a server
redirects to an mms:// protocol URL we need to rewrite the link and set proper headers.

=cut

sub handleRedirect {
	my ( $request, $track, $args ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug( 'Server redirected to ' . $request->uri );

	if ( $request->uri =~ /^mms/ ) {

		if ( main::DEBUGLOG && $log->is_debug ) {
			$log->debug("Server redirected to MMS URL: " . $request->uri . ", adding WMA headers");
		}

		addWMAHeaders( $request );
	}

	# Keep track of artwork or station icon across redirects
	my $cache = Slim::Utils::Cache->new();
	if ( my $icon = $cache->get("remote_image_" . $track->url) ) {
		$cache->set("remote_image_" . $request->uri->canonical->as_string, $icon, '30 days');
	}

	return $request;
}

=head2 readRemoteHeaders( $http, $track, $args )

Async callback from scanURL.  The remote headers are read to determine the content-type.

=cut

sub readRemoteHeaders {
	my ( $http, $track, $args ) = @_;

	my $client = $args->{client};
	my $cb     = $args->{cb} || sub {};
	my $pt     = $args->{pt} || [];

	# $track is the track object for the original URL we scanned
	# $url is the final URL, may be different due to a redirect

	my $url = $http->request->uri->canonical->as_string;

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug( "Headers for $url are " . Data::Dump::dump( $http->response->headers ) );
	}

	# Make sure the content type of the track is correct
	my $type = $http->response->content_type;

	# Content-Type may have multiple elements, i.e. audio/x-mpegurl; charset=ISO-8859-1
	if ( ref $type eq 'ARRAY' ) {
		$type = $type->[0];
	}

	$type = Slim::Music::Info::mimeToType($type) || $type;

	# Handle some special cases

	# Bug 3396, some m4a audio is incorrectly served as audio/mpeg.
	# In this case, prefer the file extension to the content-type
	if ( $url =~ /aac$/i && ($type eq 'mp3' || $type eq 'txt') ) {
		$type = 'aac';
	}
	elsif ( $url =~ /(?:m4a|mp4)$/i && ($type eq 'mp3' || $type eq 'txt') ) {
		$type = 'mp4';
	}

	# bug 15491 - some radio services are too lazy to correctly configure their servers
	# thus serve playlists with content-type text/html or text/plain
	elsif ( $type =~ /(?:htm|txt)/ && $url =~ /\.(asx|m3u|pls|wpl|wma)$/i ) {
		$type = $1;
	}

	# KWMR misconfiguration
	elsif ( $type eq 'wma' && $url =~ /\.(m3u)$/i ) {
		$type = $1;
	}

	# fall back to m3u for html and text
	elsif ( $type =~ /(?:htm|txt)/ ) {
		$type = 'm3u';
	}

	# https://forums.slimdevices.com/forum/user-forums/logitech-media-server/1661990
	elsif ( $type =~ /octet-stream/ ) {
		my $validTypeExtensions = join('|', Slim::Music::Info::validTypeExtensions());
		if ($url =~ /\.($validTypeExtensions)\b/) {
			$type = $1;
		}
	}

	# Some Shoutcast/Icecast servers don't send content-type
	if ( !$type && $http->response->header('icy-name') ) {
		$type = 'mp3';
	}

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug( "Content-type for $url detected as $type (" . $http->response->content_type . ")" );
	}

	# Set content-type for original URL and redirected URL
	main::DEBUGLOG && $log->is_debug && $log->debug( 'Updating content-type for ' . $track->url . " to $type" );
	Slim::Schema->clearContentTypeCache( $track->url );
	$track = Slim::Music::Info::setContentType( $track->url, $type );

	if ( $track->url ne $url ) {
		my $update;

		# Don't create a duplicate object if the only difference is http:// instead of mms://
		if ( $track->url =~ m{^mms://(.+)} ) {
			if ( $url ne "http://$1" ) {
				$update = 1;
			}
		}
		else {
			$update = 1;
		}

		if ( $update ) {
			main::DEBUGLOG && $log->is_debug && $log->debug( "Updating redirected URL $url" );

			# Get/create a new entry for the redirected track
			my $redirTrack = Slim::Schema->updateOrCreate( {
				url => $url,
			} );

			# Copy values from original track
			$redirTrack->title( $track->title );
			$redirTrack->content_type( $track->content_type );
			$redirTrack->bitrate( $track->bitrate );
			$redirTrack->redir( $track->redir || $track->url );

			$redirTrack->update;

			# Delete original track
			$track->delete;

			$track = $redirTrack;
		}
	}

	# Is this an audio stream or a playlist?
	if ( $type = Slim::Music::Info::isSong( $track, $type ) ) {
		main::INFOLOG && $log->is_info && $log->info("This URL is an audio stream [$type]: " . $track->url);

		$track->content_type($type);

		if ( $type eq 'wma' ) {
			# WMA streams require extra processing, we must parse the Describe header info

			main::DEBUGLOG && $log->is_debug && $log->debug('Reading WMA header');

			# If URL was http but content-type is wma, change URL
			if ( $track->url =~ /^http/i ) {
				# XXX: may create duplicate track entries
				my $mmsURL = $track->url;
				$mmsURL =~ s/^http/mms/i;
				$track->url( $mmsURL );
				$track->update;
			}

			# Read the rest of the header and pass it on to parseWMAHeader
			$http->read_body( {
				readLimit   => 128 * 1024,
				onBody      => \&parseWMAHeader,
				passthrough => [ $track, $args ],
			} );
		}
		elsif ( $type eq 'aac' ) {
			# Bug 16379, AAC streams require extra processing to check for the samplerate

			main::DEBUGLOG && $log->is_debug && $log->debug('Reading AAC header');

			$http->read_body( {
				readLimit   => 4 * 1024,
				onBody      => \&parseAACHeader,
				passthrough => [ $track, $args ],
			} );
		}
		elsif ( $type eq 'flc' ) {

			main::DEBUGLOG && $log->is_debug && $log->debug('Reading FLAC header');

			$http->read_body( {
				onStream    => \&parseFlacHeader,
				passthrough => [ $track, $args ],
			} );
		}
		elsif ( $type eq 'ogg' ) {

			# Read the header to allow support for oggflac as it requires different decode path
			main::DEBUGLOG && $log->is_debug && $log->debug('Reading Ogg header');

			$http->read_body( {
				readLimit   => 64,
				onBody      => \&parseOggHeader,
				passthrough => [ $track, $args ],
			} );
		}
		elsif ( $type eq 'wav' || $type eq 'aif') {

			# Read the header to allow support for wav/aif as it requires different decode path
			main::DEBUGLOG && $log->is_debug && $log->debug('Reading $type header');

			$http->read_body( {
				onStream     => \&parseWavAifHeader,
				passthrough => [ $track, $args, $type ],
			} );
		}
		elsif ( $type eq 'mp4' ) {

			# Read the header and optionally seek across file
			main::DEBUGLOG && $log->is_debug && $log->debug('Reading mp4 header');

			$http->read_body( {
				onStream      => \&parseMp4Header,
				passthrough => [ $track, $args, $url ],
			} );
		}
		else {
			# If URL was mms but content-type is not wma, change URL
			if ( $track->url =~ /^mms/i ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("URL was mms:// but content-type is $type, fixing URL to http://");

				# XXX: may create duplicate track entries
				my $httpURL = $track->url;
				$httpURL =~ s/^mms/http/i;
				$track->url( $httpURL );
				$track->update;
			}

			my $bitrate;
			my $vbr = 0;

			# Look for Icecast info header and determine bitrate from this
			if ( my $audioinfo = $http->response->header('ice-audio-info') ) {
				($bitrate) = $audioinfo =~ /ice-(?:bitrate|quality)=([^;]+)/i;
				if ( $bitrate =~ /(\d+)/ ) {
					if ( $bitrate <= 10 ) {
						# Ogg quality, may be fractional
						my $quality = sprintf "%d", $1;
						$bitrate = $ogg_quality{$quality};
						$vbr = 1;

						main::DEBUGLOG && $log->is_debug && $log->debug("Found bitrate from Ogg quality header: $bitrate");
					}
					else {
						main::DEBUGLOG && $log->is_debug && $log->debug("Found bitrate from ice-audio-info header: $bitrate");
					}
				}
			}

			# Look for bitrate information in header indicating it's an Icy stream
			elsif ( $bitrate = ( $http->response->header('icy-br') || $http->response->header('x-audiocast-bitrate') || 0 ) * 1000 ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Found bitrate in Icy header: $bitrate");
			}

			if ( $bitrate ) {
				if ( $bitrate < 1000 ) {
					$bitrate *= 1000;
				}

				Slim::Music::Info::setBitrate( $track, $bitrate, $vbr );

				if ( $track->url ne $url ) {
					$log->warn("don't know what we are doing here $url ", $track->url);
					Slim::Music::Info::setBitrate( $url, $bitrate, $vbr );
				}

				# We don't need to read any more data from this stream
				$http->disconnect;

				# All done

				# Bug 11001, if the URL uses basic authentication, it may be an Icecast
				# server that allows only 1 connection per user.  Delay this callback for a second
				# to avoid the chance of getting a 401 error when trying to stream.
				if ( $track->url =~ m{https?://[^:]+:[^@]+@} ) {
					main::DEBUGLOG && $log->is_debug && $log->debug( 'Auth stream detected, waiting 1 second before streaming' );

					Slim::Utils::Timers::setTimer(
						undef,
						Time::HiRes::time() + 1,
						sub {
							$cb->( $track, undef, @{$pt} );
						},
					);
				}
				else {
					$cb->( $track, undef, @{$pt} );
				}
			}
			else {
				# XXX - for whatever reason we have to disconnect an https connection before we can do another connection...
				# or bitrate is mandatory, so we'll start playback once the scanning has finished
				if ( $track->url =~ /^https/ ) {
					# as https for whatever reason didn't allow us to start the stream while scanning
					# we're now disconnecting to allow the stream to start
					$args->{cb} = sub {
						my $track = shift;
						my $param = shift;
						$http->disconnect;
						$cb->( $track, $param, @_ );
					};
				} elsif ( !$args->{song}->seekdata || !$args->{song}->seekdata->{startTime} ) {
					# We still need to read more info about this stream, but we can begin playing it now - unless it's an https stream
					$cb->( $track, undef, @{$pt} );
					delete $args->{cb};
				}

				# We may be able to determine the bitrate or other tag information
				# about this remote stream/file by reading a bit of audio data
				main::DEBUGLOG && $log->is_debug && $log->debug('Reading audio data to detect bitrate and/or tags');

				# read as much as is necessary to read all ID3v2 tags and determine bitrate
				$http->read_body( {
					onStream    => \&parseAudioStream,
					passthrough => [ $track, $args, $url ],
				} );
			}
		}
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug('This URL is a playlist: ' . $track->url);

		# Read the rest of the playlist
		$http->read_body( {
			readLimit   => 128 * 1024,
			onBody      => \&parsePlaylist,
			passthrough => [ $track, $args ],
		} );
	}
}

sub parseWMAHeader {
	my ( $http, $track, $args ) = @_;

	my $client = $args->{client};
	my $cb	   = $args->{cb} || sub {};
	my $pt	   = $args->{pt} || [];

	# Check for WMA chunking header from a server and remove it
	my $header	  = $http->response->content;
	my $chunkType = unpack 'v', substr( $header, 0, 2 );
	if ( $chunkType == 0x4824 ) {
		substr $header, 0, 12, '';
	}

	# The header may be at the front of the file, if the remote
	# WMA file is not a live stream
	my $fh = File::Temp->new();
	$fh->write( $header, length($header) );
	$fh->seek(0, 0);

	my $wma = Audio::Scan->scan_fh( asf => $fh );

	if ( !$wma->{info}->{max_bitrate} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Unable to parse WMA header');

		# Delete bad item
		$track->delete;

		return $cb->( undef, 'ASF_UNABLE_TO_PARSE', @{$pt} );
	}

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug( 'WMA header data for ' . $track->url . ': ' . Data::Dump::dump($wma) );
	}

	my $streamNum = 1;

	# Some ASF streams appear to have no stream objects (mms://ms1.capitalinteractive.co.uk/fm_high)
	# I think it's safe to just assume stream #1 in this case
	if ( ref $wma->{info}->{streams} ) {

		# Look through all available streams and select the one with the highest bitrate still below
		# the user's preferred max bitrate
		my $max = preferences('server')->get('maxWMArate') || 9999;

		my $bitrate = 0;
		my $valid	= 0;

		for my $stream ( @{ $wma->{info}->{streams} } ) {
			next unless defined $stream->{stream_number};

			my $streamBitrate = sprintf "%d", $stream->{bitrate} / 1000;

			# If stream is ASF_Command_Media, it may contain metadata, so let's get it
			if ( $stream->{stream_type} eq 'ASF_Command_Media' ) {
				main::DEBUGLOG && $log->is_debug && $log->debug( "Possible ASF_Command_Media metadata stream: \#$stream->{stream_number}, $streamBitrate kbps" );
				$args->{song}->wmaMetadataStream($stream->{stream_number});
				next;
			}

			# Skip non-audio streams or audio codecs we can't play
			# The firmware supports 2 codecs:
			# Windows Media Audio V7 / V8 / V9 (0x0161)
			# Windows Media Audio 9 Voice (0x000A)
			next unless $stream->{codec_id} && (
				$stream->{codec_id} == 0x0161
				||
				$stream->{codec_id} == 0x000a
			);

			main::DEBUGLOG && $log->is_debug && $log->debug( "Available stream: \#$stream->{stream_number}, $streamBitrate kbps" );

			if ( $stream->{bitrate} > $bitrate && $max >= $streamBitrate ) {
				$streamNum = $stream->{stream_number};
				$bitrate   = $stream->{bitrate};
			}

			$valid++;
		}

		# If we saw no valid streams, such as a stream with only MP3 codec, give up
		if ( !$valid ) {
			main::DEBUGLOG && $log->is_debug && $log->debug('WMA contains no valid audio streams');

			# Delete bad item
			$track->delete;

			return $cb->( undef, 'ASF_UNABLE_TO_PARSE', @{$pt} );
		}

		if ( !$bitrate && ref $wma->{info}->{streams}->[0] ) {
			# maybe we couldn't parse bitrate information, so just use the first stream
			$streamNum = $wma->{info}->{streams}->[0]->{stream_number};
		}

		if ( $bitrate ) {
			Slim::Music::Info::setBitrate( $track, $bitrate );
		}

		if ( main::DEBUGLOG && $log->is_debug ) {
			$log->debug( sprintf( "Will play stream #%d, bitrate: %s kbps",
				$streamNum,
				$bitrate ? int( $bitrate / 1000 ) : 'unknown',
			) );
		}
	}

	# Set duration if available (this is not a broadcast stream)
	if ( my $ms = $wma->{info}->{song_length_ms} ) {
		Slim::Music::Info::setDuration( $track, int($ms / 1000) );
	}

	# Save this metadata for the MMS protocol handler to use
	if ( my $song = $args->{song} ) {
		my $sd = $song->scanData();
		if (!defined $sd) {
			$song->scanData($sd = {});
		}
		$sd->{$track->url} = {
			streamNum => $streamNum,
			metadata  => $wma,
			headers	  => $http->response->headers,
		};
	}

	# All done
	$cb->( $track, undef, @{$pt} );
}

sub parseAACHeader {
	my ( $http, $track, $args ) = @_;

	my $client = $args->{client};
	my $cb	   = $args->{cb} || sub {};
	my $pt	   = $args->{pt} || [];

	my $header = $http->response->content;

	my $fh = File::Temp->new();
	$fh->write( $header, length($header) );
	$fh->seek(0, 0);

	my $aac = Audio::Scan->scan_fh( aac => $fh );

	if ( my $samplerate = $aac->{info}->{samplerate} ) {
		$track->samplerate($samplerate);
		main::DEBUGLOG && $log->is_debug && $log->debug("AAC samplerate: $samplerate");
	}

	# All done
	$cb->( $track, undef, @{$pt} );
}

sub parseFlacHeader {
	my ( $http, $dataref, $track, $args ) = @_;

	Slim::Formats->loadTagFormatForType('flc');
	my $formatClass = Slim::Formats->classForFormat('flc');
	my $info = $formatClass->parseStream($dataref, $args, $http->response->content_length);

	return 1 if ref $info ne 'HASH' && $info;

	$track->content_type('flc');

	if ($info) {
		# don't set audio_offset & audio_size as these are not reliable here
		$track->samplerate( $info->{samplerate} );
		$track->samplesize( $info->{bits_per_sample} );
		$track->channels( $info->{channels} );
		# if no bitrate, swag it to allow seek
		my $bitrate = $info->{avg_bitrate} || int($info->{samplerate} * $info->{bits_per_sample} * $info->{channels} * 0.6);
		Slim::Music::Info::setBitrate( $track, $bitrate );
		Slim::Music::Info::setDuration( $track, $info->{song_length_ms} / 1000 );

		# we have valid header, means there will be no alignment unless we seek
		$track->processors('flc', Slim::Schema::RemoteTrack::INITIAL_BLOCK_ONSEEK, \&Slim::Formats::FLAC::initiateFrameAlign);
	} else {
		# if we don't have an header, need to always process
		$track->processors('flc', Slim::Schema::RemoteTrack::INITIAL_BLOCK_ALWAYS, \&Slim::Formats::FLAC::initiateFrameAlign );
	}

	# All done
	$args->{cb}->( $track, undef, @{$args->{pt} || []} );
	return 0;
}

sub parseMp4Header {
	my ( $http, $dataref, $track, $args, $url ) = @_;

	Slim::Formats->loadTagFormatForType('mp4');
	my $formatClass = Slim::Formats->classForFormat('mp4');

	# parse chunk
	my $info = $formatClass->parseStream($dataref, $args, $http->response->content_length);

	if ( ref $info ne 'HASH' ) {
		if ( !$info ) {
			# error, can't continue
			$log->error("unable to parse mp4 header");
			$args->{cb}->( $track, undef, @{$args->{pt} || []} );
			return 0;
		}
		elsif ( $info < 0 ) {
			# need more data
			return 1;
		}
		else {
			# please restart from offset set by $info, keep current request's custom fields...
			my $query = Slim::Networking::Async::HTTP->new;
			$http->disconnect;
			$http->request->header('Range' => "bytes=$info-");

			# re-calculate header all the time (i.e. can't go direct at all)
			$args->{initial_block_type} = Slim::Schema::RemoteTrack::INITIAL_BLOCK_ALWAYS;

			main::INFOLOG && $log->is_info && $log->info("'mdat' reached before 'moov' at ", length($args->{_scanbuf}), " => seeking with $args->{_range}");

			$query->send_request( {
				request    => $http->request,
				onStream   => \&parseMp4Header,
				onError    => sub {
						my ($self, $error) = @_;
						$log->error( "could not find MP4 header $error" );
						$args->{cb}->( $track, undef, @{$args->{pt} || []} );
				},
				passthrough => [ $track, $args, $url ],
			} );

			return 0;
		}
	}

	# got everything we need, set the $track context
	my ($samplesize, $channels);
	my $samplerate = $info->{samplerate};
	my $duration = $info->{song_length_ms} / 1000;
	my $bitrate = $info->{avg_bitrate};

	if ( my $item = $info->{tracks}->[0] ) {
		my $format = 'mp4';

		$samplesize = $item->{bits_per_sample};
		$channels = $item->{channels};

		# If encoding is alac, the file is lossless
		if ( $item->{encoding} && $item->{encoding} eq 'alac' ) {
			$format = 'alc';
			# bitrate will be wrong b/c we only gave a header, not a real file
			$bitrate = $duration ? $track->audio_size * 8 / $duration : 850_000;
		}
		elsif ( $item->{encoding} && $item->{encoding} eq 'drms' ) {
			$track->drm(1);
		}

		# Check for HD-AAC file, if the file has 2 tracks and AOTs of 2/37
		if ( defined $item->{audio_object_type} && (my $item2 = $info->{tracks}->[1]) ) {
			if ( $item->{audio_object_type} == 2 && $item2->{audio_object_type} == 37 ) {
				$samplesize   = $item2->{bits_per_sample};
				$format = 'sls';
			}
		}

		# use process_audio hook & format if set by parser
		foreach ( keys %{$info->{processors}} ) {
			$track->processors($_, Slim::Schema::RemoteTrack::INITIAL_BLOCK_ALWAYS, $info->{processors}->{$_});
		}

		# change track attributes if format has been altered
		if ( $format ne $track->content_type ) {
			Slim::Schema->clearContentTypeCache( $track->url );
			Slim::Music::Info::setContentType( $track->url, $format );
			$track->content_type($format);
		}
	} else	{
		$log->warn("no playable track found");
		$args->{cb}->( $track, undef, @{$args->{pt} || []} );
		return 0;
	}

	# some mp4 file have wrong mdat length
	if ($info->{audio_offset} + $info->{audio_size} > $http->response->content_length) {
		$log->warn("inconsistent audio offset/size $info->{audio_offset}+$info->{audio_size}and content_length ", $http->response->content_length);
		$track->audio_size($http->response->content_length - $info->{audio_offset});
	} else {
		$track->audio_size($info->{audio_size});
	}
	$track->audio_offset($info->{audio_offset});
	$track->samplerate($samplerate);
	$track->samplesize($samplesize);
	$track->channels($channels);
	Slim::Music::Info::setBitrate( $track, $bitrate );
	Slim::Music::Info::setDuration( $track, $duration );

	# use the audio block to stash the temp file handler
	$track->initial_block_fn($info->{fh}->filename);
	$info->{fh}->unlink_on_destroy(0);
	$info->{fh}->close;
	$track->processors($track->content_type, $args->{initial_block_type} // Slim::Schema::RemoteTrack::INITIAL_BLOCK_ONSEEK);

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug( sprintf( "mp4: %dHz, %dBits, %dch => bitrate: %dkbps (ofs:%d, len:%d, hdr:%d)",
					$samplerate, $samplesize, $channels, int( $bitrate / 1000 ),
					$track->audio_offset, $track->audio_size, length $args->{_scanbuf}) );
	}

	# All done
	$args->{cb}->( $track, undef, @{$args->{pt} || []} );
	return 0;
}

sub parseOggHeader {
	my ( $http, $track, $args ) = @_;

	my $client = $args->{client};
	my $cb	   = $args->{cb} || sub {};
	my $pt	   = $args->{pt} || [];

	my $header = $http->response->content;
	my $data   = substr($header, 28);

	# search for Ogg FLAC headers within the data - if so change the content type to ogf for OggFlac
	# OggFlac header defined: http://flac.sourceforge.net/ogg_mapping.html
	if (substr($data, 0, 5) eq "\x7fFLAC" && substr($data, 9,4) eq 'fLaC') {
		main::DEBUGLOG && $log->is_debug && $log->debug("Ogg stream is OggFlac - setting content type [ogf]");
		Slim::Schema->clearContentTypeCache( $track->url );
		Slim::Music::Info::setContentType( $track->url, 'ogf' );
		$track->content_type('ogf');

		my $samplerate = (unpack('N', substr($data, 26, 4)) & 0x00fffff0)>>4;
		my $samplesize = ((unpack('n', substr($data, 29, 2)) & 0x01f0)>>4)+1;
		my $channels = ((unpack('C', substr($data, 29, 1)) & 0x0e)>>1)+1;
		my $bitrate = 0.6 * $samplerate * $samplesize * $channels;
		$track->samplerate($samplerate);
		$track->samplesize($samplesize);
		$track->channels($channels);
		Slim::Music::Info::setBitrate( $track->url, $bitrate );
		if ( main::DEBUGLOG && $log->is_debug ) {
			$log->debug( sprintf( "OggFlac: %dHz, %dBits, %dch => estimated bitrate: %dkbps",
					      $samplerate, $samplesize, $channels, int( $bitrate / 1000 ) ) );
		}
	# search for Ogg Opus header within the data - if so change the content type to opus for OggOpus
	# OggOpus header defined: https://people.xiph.org/~giles/2013/draft-ietf-codec-oggopus.html#rfc.section.5.1
	}
	elsif (substr($data, 0, 8) eq 'OpusHead') {
		main::DEBUGLOG && $log->is_debug && $log->debug("Ogg stream is OggOpus - setting content type [ops]");
		Slim::Schema->clearContentTypeCache( $track->url );
		Slim::Music::Info::setContentType( $track->url, 'ops' );
		$track->content_type('ops');

		my $samplerate = unpack('V', substr($data, 12, 4));
		my $channels = unpack('C', substr($data, 9, 1));
		$track->samplerate($samplerate);
		$track->samplesize(16);
		if ( main::DEBUGLOG && $log->is_debug ) {
			$log->debug( sprintf( "OggOpus: input %dHz, %dch", $samplerate, $channels ) );
		}
	}

	# All done
	$cb->( $track, undef, @{$pt} );
}

sub parseWavAifHeader {
	my ( $http, $dataref, $track, $args, $type ) = @_;

	Slim::Formats->loadTagFormatForType($type);
	my $formatClass = Slim::Formats->classForFormat($type);
	my $info = $formatClass->parseStream($dataref, $args, $http->response->content_length);

	return 1 if ref $info ne 'HASH' && $info;

	if (!$info) {
		$log->error("unable to parse $type header");
		$args->{cb}->( $track, undef, @{$args->{pt} || []} );
		return 0;
	}

	$track->samplerate($info->{samplerate});
	$track->samplesize($info->{samplesize});
	$track->channels($info->{channels});
	$track->endian($type eq 'wav' || $info->{compression_type} eq 'swot' ? 0 : 1);

	$track->block_alignment($info->{channels} * $info->{bits_per_sample} / 8);
	$track->audio_offset($info->{audio_offset});
	$track->audio_size($info->{audio_size});

	Slim::Music::Info::setBitrate( $track->url, $info->{bitrate} );

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug( sprintf( "$type: %dHz, %dBits, %dch => bitrate: %dkbps (ofs: %d, len: %d)",
					$info->{samplerate}, $info->{samplesize}, $info->{channels}, int( $info->{bitrate} / 1000 ),
					$track->audio_offset, $track->audio_size ) );
	}

	# we have a dynamic header but can go direct when not seeking
	$track->initial_block_fn($info->{fh}->filename);
	$info->{fh}->unlink_on_destroy(0);
	$info->{fh}->close;

	$track->processors($type, Slim::Schema::RemoteTrack::INITIAL_BLOCK_ONSEEK);

	# all done
	$args->{cb}->( $track, undef, @{$args->{pt} || []} );
	return 0;
}

sub parseAudioStream {
	my ( $http, $dataref, $track, $args, $url ) = @_;

	return 1 unless defined $$dataref;

	my $len = length($$dataref);
	my $first;

	# Buffer data to a temp file, 128K of data by default
	my $fh = $args->{_scanbuf};
	if ( !$fh ) {
		$fh = File::Temp->new();
		$args->{_scanbuf} = $fh;
		$args->{_scanlen} = 128 * 1024;
		$first = 1;
		main::DEBUGLOG && $log->is_debug && $log->debug( $track->url . ' Buffering audio stream data to temp file ' . $fh->filename );
	}

	$fh->write( $$dataref, $len );

	if ( $first ) {
		if ( $$dataref =~ /^ID3/ ) {
			# get ID3v2 tag length from bytes 7-10
			my $id3size = 0;
			my $rawsize = substr $$dataref, 6, 4;

			for my $b ( unpack 'C4', $rawsize ) {
				$id3size = ($id3size << 7) + $b;
			}

			$id3size += 10;

			# Read the full ID3v2 tag + some audio frames for bitrate
			$args->{_scanlen} = $id3size + (16 * 1024);

			# last chance to set content_type if missing
			Slim::Music::Info::setContentType( $track->url, 'mp3' ) unless $track->content_type;

			main::DEBUGLOG && $log->is_debug && $log->debug( 'ID3v2 tag detected, will read ' . $args->{_scanlen} . ' bytes' );
		}

		# XXX: other tag types may need more than 128K too

		# Reset fh back to the end
		$fh->seek( 0, 2 );
	}

	$args->{_scanlen} -= $len;

	if ( $args->{_scanlen} > 0 && $len) {
		# Read more data
		return 1;
	}

	# Parse tags and bitrate
	my $bitrate = -1;
	my $vbr;

	my $cl          = $http->response->content_length;
	my $type        = $track->content_type;
	my $formatClass = Slim::Formats->classForFormat($type);

	if ( $formatClass && Slim::Formats->loadTagFormatForType($type) && $formatClass->can('scanBitrate') ) {
		($bitrate, $vbr) = eval { $formatClass->scanBitrate( $fh, $track->url ) };

		if ( $@ ) {
			$log->error("Unable to scan bitrate for " . $track->url . ": $@");
			$bitrate = 0;
		}

		if ( $bitrate > 0 ) {
			Slim::Music::Info::setBitrate( $track, $bitrate, $vbr );
			if ($cl) {
				Slim::Music::Info::setDuration( $track, ( $cl * 8 ) / $bitrate );
			}

			# Copy bitrate to redirected URL
			if ( $track->url ne $url ) {
				$log->warn("don't know what we are doing here $url ", $track->url);
				Slim::Music::Info::setBitrate( $url, $bitrate );
				if ($cl) {
					Slim::Music::Info::setDuration( $url, ( $cl * 8 ) / $bitrate );
				}
			}
		}
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug("Unable to parse audio data for $type file");
	}

	# Update filesize with Content-Length
	if ( $cl ) {
		$track->filesize( $cl );
		$track->update;

		# Copy size to redirected URL
		if ( $track->url ne $url ) {
			my $redir = Slim::Schema->updateOrCreate( {
				url => $url,
			} );
			$redir->filesize( $cl );
			$redir->update;
		}
	}

	# Delete temp file and other data
	$fh->close;
	unlink $fh->filename if -e $fh->filename;
	delete $args->{_scanbuf};
	delete $args->{_scanlen};

	# callback if needed
	$args->{cb}->( $track, undef, @{$args->{pt} || []} ) if $args->{cb};

	# Disconnect
	return 0;
}

sub parsePlaylist {
	my ( $http, $playlist, $args ) = @_;

	my $client = $args->{client};
	my $cb     = $args->{cb} || sub {};
	my $pt     = $args->{pt} || [];

	my @results;

	my $type = $playlist->content_type;

	my $formatClass = Slim::Formats->classForFormat($type);

	if ( $formatClass && Slim::Formats->loadTagFormatForType($type) && $formatClass->can('read') ) {
		my $fh = IO::String->new( $http->response->content_ref );
		@results = eval { $formatClass->read( $fh, '', $playlist->url ) };
	}
	 elsif ( $type =~ /json/ ) {
		my $feed = eval { Slim::Formats::XML::parseXMLIntoFeed( $http->response->content_ref, $type ) };
		$@ && $log->error("Failed to parse playlist from OPML: $@");

		if ($feed && $feed->{items}) {
			$args->{song}->_playlist(1);
			@results = map {
				Slim::Schema->updateOrCreate( {
					url => $_->{play} || $_->{url},
					attributes => {
						TITLE => $_->{name},
						COVER => $_->{image},
					},
				} );
			} grep {
				$_ ->{play} || $_->{url}
			} @{$feed->{items}};
		}
	}

	if ( !scalar @results || !defined $results[0]) {
		main::DEBUGLOG && $log->is_debug && $log->debug( "Unable to parse playlist for content-type $type $@" );

		# delete bad playlist
		$playlist->delete;

		return $cb->( undef, 'PLAYLIST_NO_ITEMS_FOUND', @{$pt} );
	}

	# Convert the track to a playlist object
	$playlist = Slim::Schema->objectForUrl( {
		url => $playlist->url,
		playlist => 1,
	} );

	# Link the found tracks with the playlist
	$playlist->setTracks( \@results );

	if ( main::INFOLOG && $log->is_info ) {
		$log->info( 'Found ' . scalar( @results ) . ' items in playlist ' . $playlist->url );
		main::DEBUGLOG && $log->debug( map { $_->url . "\n" } @results );
	}

	# Scan all URLs in the playlist concurrently
	my $delay   = 0;
	my $ready   = 0;
	my $scanned = 0;
	my $total   = scalar @results;

	for my $entry ( @results ) {
		if ( !blessed($entry) ) {
			$total--;
			next;
		}

		# playlist might contain tracks with a different handler
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($entry->url);
		$handler->scanUrl( $entry->url, {
			client => $client,
			song   => $args->{song},
			depth  => $args->{depth} + 1,
			delay  => $delay,
			title  => (($playlist->title && $playlist->title =~ /^(?:http|mms)/i) ? undef : $playlist->title),
			cb     => sub {
				my ( $result, $error ) = @_;

				# Bug 10208: If resulting track is not the same as entry (due to redirect),
				# we need to adjust the playlist
				if ( blessed($result) && $result->id != $entry->id ) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Scanned track changed, updating playlist');

					my $i = 0;
					for my $e ( @results ) {
						if ( $e->id == $entry->id ) {
							splice @results, $i, 1, $result;
							last;
						}
						$i++;
					}

					# Get the $playlist object again, as it may have changed
					$playlist = Slim::Schema->objectForUrl( {
						url      => $playlist->url,
						playlist => 1,
					} );

					$playlist->setTracks( \@results );
				}

				$scanned++;

				main::DEBUGLOG && $log->is_debug && $log->debug("Scanned $scanned/$total items in playlist");

				if ( !$ready ) {
					# As soon as we find an audio URL, start playing it and continue scanning the rest
					# of the playlist in the background
					if ( my $entry = $playlist->getNextEntry ) {

						if ( $entry->bitrate ) {
							# Copy bitrate to playlist
							Slim::Music::Info::setBitrate( $playlist->url, $entry->bitrate, $entry->vbr_scale );
						}

						# Copy title if the playlist is untitled or a URL
						# If entry doesn't have a title either, use the playlist URL
						if ( !$playlist->title || $playlist->title =~ /^(?:http|mms)/i ) {
							$playlist = Slim::Music::Info::setTitle( $playlist->url, $entry->title || $playlist->url );
						}

						main::DEBUGLOG && $log->is_debug && $log->debug('Found at least one audio URL in playlist');

						$ready = 1;

						$cb->( $playlist, undef, @{$pt} );
					}
				}

				if ( $scanned == $total ) {
					main::DEBUGLOG && $log->is_debug && $log->debug( 'Playlist scan of ' . $playlist->url . ' finished' );

					# If we scanned everything and are still not ready, fail
					if ( !$ready ) {
						main::DEBUGLOG && $log->is_debug && $log->debug( 'No audio tracks found in playlist' );

						# Get error of last item we tried in the playlist, or a generic error
						my $error;
						for my $track ( $playlist->tracks ) {
							if ( $track->can('error') && $track->error ) {
								$error = $track->error;
							}
						}

						$error ||= 'PLAYLIST_NO_ITEMS_FOUND';

						# Delete bad playlist
						$playlist->delete;

						$cb->( undef, $error, @{$pt} );
					}
				}
			},
		} );

		# Stagger playlist scanning by a small amount so we prefer the first item

		# XXX: This can be a problem if a playlist file contains 'backup' streams or files
		# we would not want to play these if any of the real streams in the playlist are valid.
		$delay += 1;
	}
}

1;

