#!/bin/sh

# http://www.videolan.org/doc/streaming-howto/en/ch03.html

IP=$1
PROTO=$2
APORT=$3
VPORT=$4

if [ -z "$VPORT"]; then VPORT=$((APORT + 2 )); fi

SDPFILE="/tmp/vlc.sdp"

INFILE="/path/to/some/movie.avi"

# always defaults to 8080, no matter what we set:
#SDP="http://127.0.0.1:8080/sdp"

# notice the 3 "/" before the actual path (which might add a fourth)
SDP="file:///$SDPFILE"

#DEBUG="-vv"

nohup cvlc \
	$DEBUG \
	$INFILE \
	--sout "#transcode{venc=x264{keyint=2,idrint=2},vcodec=h264,vb=300,width=320,height=240,acodec=alaw,samplerate=8000}:rtp{dst=$IP,port-audio=$APORT,port-video=$VPORT,sdp=$SDP}" &

sleep 3;

# TODO: should we mangle the sdp file?
