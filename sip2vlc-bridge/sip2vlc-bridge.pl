#!/usr/bin/perl -w
use strict;
use 5.010;
use Net::SIP;
use Net::SIP::Debug;
use Net::SIP::Util;
use Data::Printer;
use VideoLan::Client;
use Digest::MD5 qw(md5);


# basic settings
my $user = 'youruser';
my $domain = 'your.sipdomain.org';
my $pass = 'yourpass';
my $local_ip = 'your.local.ip';
my $input = '/path/to/your.mp4';

my $vlc_ip = '127.0.0.1';
my $vlc_port = '1234';
my $vlc_pass = 'foobar';

# advanced settings, tweak if necessary
my $config = {
	registrar => $domain,
	contact => "sip:$user\@$local_ip:5678",
	from => "sip:$user\@$domain",
	auth => [ $user, $pass ],
};
my $outbound_proxy = $domain;
my $channel_name = "testchan";
my $local_media_ip = $local_ip;

# end of configuration

my $sessions = {};

my $vlcc = new VideoLan::Client (
	HOST => $vlc_ip,
	PORT => $vlc_port,
	PASSWD => $vlc_pass,
);
$vlcc->login or CRITICAL("failed to connect to vlc");

sub CRITICAL {
	my @args = @_;
	say $args[0];
	exit 1;
}
sub generate_sig {
	my ($pkg) = @_;

	my $from = Net::SIP::Util::sip_hdrval2parts('from', $pkg->get_header('from'));
	my $to = Net::SIP::Util::sip_hdrval2parts('to', $pkg->get_header('to'));
	my $sig = $pkg->callid . '_#_' . $from->{tag} . '_#_' . $to->{tag};
	DEBUG $sig;
	return md5($sig);
}

my $shutdown = 0;
$SIG{'INT'} = sub {
	DEBUG("shutting down");
	$shutdown = 1;
};

Net::SIP::Debug->level(3);


my $loop = Net::SIP::Dispatcher::Eventloop->new;
my @legs;
my $sock = Net::SIP::Util::create_socket_to($outbound_proxy) or die
	"failed to create socket to $outbound_proxy";
push @legs, Net::SIP::Leg->new(sock => $sock);

my $dispatcher = Net::SIP::Dispatcher->new(
	\@legs,
	$loop,
);
my $ua = Net::SIP::Endpoint->new($dispatcher);
my $ctx = $ua->register(
	%{ $config }, 
	expires => 86400,
	callback => sub {
		my ($endpoint, $ctx, $tmp, $code, $res, $leg, $peer) = @_;
		unless($code >=  200 && $code < 300) {
			DEBUG("failed to register");
			$shutdown = 1;
		} else {
			DEBUG("sucessfully registered");
		}
	}
);

$ua->set_application(sub {
	my ($endpoint, $ctx, $req, $leg, $peer) = @_;
	DEBUG("got packet");

	if($req->method eq "OPTIONS") {
		DEBUG("send 200 for OPTIONS");
		my $res = $req->create_response(200, "OK");
		$endpoint->new_response($ctx, $res, $leg, $peer);
		return;
	} elsif($req->method eq "INVITE") {
		DEBUG("got INVITE");

		if(keys %{ $sessions } > 4) {
			my $res = $req->create_response(486, "Max concurrent streams reached, try again later");
			DEBUG "rejecting session, max reached";
			$endpoint->new_response($ctx, $res, $leg, $peer);
			return;
		}

		DEBUG "creating new session";
		my $res;
		my $sdp = $req->sdp_body;

		my @media = $sdp->get_media;
		my $remote = {};
		foreach my $m(@media) {
			$remote->{$m->{media}} = $m;
		}

		my $media = {};

		$media->{audio}->{codec} = "opus/48000/2";
		$media->{audio}->{id} = $sdp->name2int($media->{audio}->{codec}, "audio");
		if(defined $media->{audio}->{id}) {
			$media->{audio}->{vlcopts} = 'acodec=opus,ab=96,channels=2,samplerate=48000';
			$media->{audio}->{a} = [ 
				"rtpmap:" . $media->{audio}->{id} . " " . $media->{audio}->{codec},
				#"fmtp:" . $media->{audio}->{id} . " usedtx=1",
				"fmtp:" . $media->{audio}->{id} . " ptime=20",
			];
		} else {
			$media->{audio}->{codec} = "PCMA/8000";
			$media->{audio}->{id} = $sdp->name2int($media->{audio}->{codec}, "audio");
			$media->{audio}->{vlcopts} = 'acodec=alaw,samplerate=8000,channels=1';
			$media->{audio}->{a} = [ 
				"rtpmap:" . $media->{audio}->{id} . " " . $media->{audio}->{codec},
			];
		}

		$media->{video}->{codec} = "VP8/90000";
		$media->{video}->{id} = $sdp->name2int($media->{video}->{codec}, "video");
		if(defined $media->{video}->{id}) {
			$media->{video}->{a} = [
				"rtpmap:" . $media->{video}->{id} . " " . $media->{video}->{codec}, 
			];
			$media->{video}->{vlcopts} = 'vcodec=VP80';
		} else {
			$media->{video}->{codec} = "H264/90000";
			$media->{video}->{id} = $sdp->name2int($media->{video}->{codec}, "video");
			$media->{video}->{a} = [
				"rtpmap:" . $media->{video}->{id} . " " . $media->{video}->{codec}, 
			];
			$media->{video}->{vlcopts} = 'venc=x264{profile=baseline,preset=ultrafast,level=31},vcodec=h264';

		}

		#my $video_id = $sdp->name2int("VP8/90000", "video");
		unless(defined $media->{audio}->{id} && defined $media->{video}->{id}) {
			$res = $req->create_response('488', 'Not Acceptable Here');
			$endpoint->new_response($ctx, $res, $leg, $peer);
			return;
		}

		foreach('audio', 'video') {
			DEBUG(sprintf "sending $_ to %s:%d",
				$remote->{$_}->{addr},
				$remote->{$_}->{port},
			);
		}

		my $rand = int(rand(999999));
		my $sdpfile = "/tmp/vlcua$rand.sdp";

		my $channel_name_local = $channel_name . '_' . $rand;

		my @ret;
		@ret = $vlcc->cmd("new $channel_name_local broadcast enabled");
		@ret = $vlcc->cmd("setup $channel_name_local input $input");
		my $cmd = "setup $channel_name_local output #transcode{".$media->{video}->{vlcopts}.",vb=300,width=318,height=132,".$media->{audio}->{vlcopts}."}:rtp{dst=".$remote->{audio}->{addr}.",port-audio=".$remote->{audio}->{port}.",port-video=".$remote->{video}->{port}.",ptype-video=".$media->{video}->{id}.",ptype-audio=".$media->{audio}->{id}.",sdp=file:///$sdpfile}";
		DEBUG $cmd;
		@ret = $vlcc->cmd($cmd);
		@ret = $vlcc->cmd("control $channel_name_local play");

		DEBUG "using media codec " . $media->{video}->{codec};
		if($media->{video}->{codec} eq "H264/90000") {
			DEBUG ">>>>>>>>>>>>> fetching sdp from vlc $sdpfile";
			# TODO: video is sometimes only added later to the sdp,
			# so it'd be cleaner to regularly check the sdp file
			# for a video fmtp param:
			sleep 2;
			for(my $i = 0; $i < 10; ++$i) {
				last if -f $sdpfile;
				DEBUG "waiting for sdp to get ready #$i";
				sleep 1;
			}
			my $fh; open $fh, "<", $sdpfile;
			my @vlcsdp = <$fh>;
			close $fh;
			DEBUG ">>>>>>>>>>>>> here is the sdp from vlc";
			use Data::Printer; p @vlcsdp;
			my $video_id = $media->{video}->{id};
			DEBUG ">>>>>>>>>>>>> searching for fmtp of video id " . $media->{video}->{id};
			foreach(@vlcsdp) {
				if(/^a=(fmtp:$video_id .+)$/) {
					DEBUG ">>>>>>>>>>>>> found fmtp '$1'";
					push @{ $media->{video}->{a} }, $1;
					last;
				}
			}
		}
		use Data::Printer; p $media->{video};

		my $res_sdp = Net::SIP::SDP->new_from_parts(
			{
				addr => $local_media_ip,
				#a => [ "recvonly" ],
			},
			{
				port => 9876,
				range => 2,
				media => "audio",
				proto => "RTP/AVP",
				fmt => [ $media->{audio}->{id} ],
				a => $media->{audio}->{a},
			},
			{
				port => 9878,
				range => 2,
				media => "video",
				proto => "RTP/AVP",
				fmt => [ $media->{video}->{id} ],
				a => $media->{video}->{a},
			},
		);
		$res = $req->create_response('200', 'OK');
		$res->set_body($res_sdp);
		$endpoint->new_response($ctx, $res, $leg, $peer);

		my $sig = generate_sig($res);
		$sessions->{$sig} = {
			channel => $channel_name_local,
		};
		return;
	} elsif($req->method eq "ACK") {
		DEBUG("got ACK");
	} elsif($req->method eq "BYE") {
		DEBUG("got BYE");
		my $sig = generate_sig($req);
		my $channel_name_local = $sessions->{$sig}->{channel};
		my @ret;
		@ret = $vlcc->cmd("control $channel_name_local stop");
		@ret = $vlcc->cmd("del $channel_name_local");
		delete $sessions->{$sig};
	}
});


$loop->loop(undef, \$shutdown);

DEBUG("unregistering");
$shutdown = 0;
$ua->register(
	%{ $config }, 
	expires => 0,
	callback => sub {
		my ($endpoint, $ctx, $tmp, $code, $res, $leg, $peer) = @_;
		unless($code >=  200 && $code < 300) {
			DEBUG("failed to unregister");
		}
		# shutdown nonetheless
		$shutdown = 1;
	}
);
$loop->loop(undef, \$shutdown);
$vlcc->logout;
DEBUG("done");
exit 0;
