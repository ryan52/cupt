package Cupt::Download::Methods::Curl;

use strict;
use warnings;
use 5.10.0;

use base qw(Cupt::Download::Method);

use WWW::Curl::Easy 4.05;
use WWW::Curl::Share;
use URI;

use Cupt::Core;

our $_curl_share_handle = new WWW::Curl::Share;
$_curl_share_handle->setopt(CURLOPT_SHARE, CURL_LOCK_DATA_COOKIE);
$_curl_share_handle->setopt(CURLOPT_SHARE, CURL_LOCK_DATA_DNS);
# those two are undocumented somewhy, but potentially useful ones
$_curl_share_handle->setopt(CURLOPT_SHARE, CURL_LOCK_DATA_CONNECT);
$_curl_share_handle->setopt(CURLOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);

sub perform ($$$$$) {
	my ($self, $config, $uri, $filename, $sub_callback) = @_;

	my $curl = new WWW::Curl::Easy;
	open(my $fd, '>>', $filename) or
			mydie("unable to open file '%s': %s", $filename, $!);

	my $total_bytes = tell($fd);
	my $is_expected_size_reported = 0;

	my $sub_writefunction = sub {
		# writing data to file
		print $fd $_[0];

		if (!$is_expected_size_reported) {
			$sub_callback->('expected-size', $curl->getinfo(CURLINFO_CONTENT_LENGTH_DOWNLOAD) + $total_bytes);
			$is_expected_size_reported = 1;
		}

		my $written_bytes = length($_[0]);
		$total_bytes += $written_bytes;
		$sub_callback->('downloading', $total_bytes);

		return $written_bytes;
	};

	my $protocol = URI->new($uri)->scheme();

	$curl->setopt(CURLOPT_URL, $uri);
	my $download_limit = $config->var("acquire::${protocol}::dl-limit");
	$curl->setopt(CURLOPT_MAX_RECV_SPEED_LARGE, $download_limit*1024) if defined $download_limit;
	my $proxy = $config->var("acquire::${protocol}::proxy");
	$curl->setopt(CURLOPT_PROXY, $proxy) if defined $proxy;
	$curl->setopt(CURLOPT_WRITEFUNCTION, $sub_writefunction);
	# FIXME: replace 1 with CURL_NETRC_OPTIONAL after libwww-curl is advanced to provide it
	$curl->setopt(CURLOPT_NETRC, 1);
	$curl->setopt(CURLOPT_RESUME_FROM, tell($fd));

	my $curl_result = $curl->perform();

	close($fd) or
			mydie("unable to close file '%s': %s", $filename, $!);

	if ($curl_result == 0) {
		# all went ok
		return 0;
	# FIXME: replace 18 with CURLE_PARTIAL_FILE after libwww-curl is advanced to provide it
	} elsif ($curl_result == 18) {
		# partial data? no problem, we may requested it
		return 0;
	} else {
		# something went wrong
		return $curl_result . $curl->strerror($curl_result);
	}
}

1;
