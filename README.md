# VLCstream

A SIP user-agent implementation to register on a SIP server and stream media (e.g. a movie) to a calling party.

## Concept

This works by running VLC in head-less mode and control it via the telnet interface from a simple Perl-based SIP
user agent.

VLC makes sure to pump the media out via RTP using H264/Opus transcoding, whereas the Perl part controls starting
and stopping the streaming and handling the SIP signalling.

## Prerequisites

At least the last time I checked (2015, I believe it was version 2.1.6), VLC still required a patch for proper SDP ptype
handling in order to match up offer and answer ids for it to work. Therefore, you have to download the sources, apply the
provided patch and recompile with H264, VP8 and Opus transcoding support.

