package File::Download;

# use 'our' on v5.6.0
use vars qw($VERSION @EXPORT_OK %EXPORT_TAGS $DEBUG);

$DEBUG = 0;
$VERSION = '0.1';

use base qw(Class::Accessor);
File::Download->mk_accessors(qw(mode overwrite outfile flength size status user_agent));

# We are exporting functions
use base qw/Exporter/;

# Export list - to allow fine tuning of export table
@EXPORT_OK = qw( download );

use strict;
use LWP::UserAgent ();
use LWP::MediaTypes qw(guess_media_type media_suffix);
use URI ();
use HTTP::Date ();

# options:
# - url
# - filename
# - username
# - password
# - overwrite
# - mode ::= a|b

sub DESTROY { }

$SIG{INT} = sub { die "Interrupted\n"; };

$| = 1;  # autoflush

sub download {
    my $self = shift;
    my ($url) = @_;
    my $file;
    $self->{user_agent} = LWP::UserAgent->new(
	agent => "File::Download/$VERSION ",
	keep_alive => 1,
	env_proxy => 1,
	) if !$self->{user_agent};
    my $ua = $self->{user_agent};
    my $res = $ua->request(HTTP::Request->new(GET => $url),
      sub {
	  $self->{status} = "Beginning download\n";
	  unless(defined $self->{outfile}) {
	      my ($chunk,$res,$protocol) = @_;

	      my $directory;
	      if (defined $self->{outfile} && -d $self->{outfile}) {
		  ($directory, $self->{outfile}) = ($self->{outfile}, undef);
	      }

	      unless (defined $self->{outfile}) {
		  # find a suitable name to use
		  $file = $res->filename;
		  # if this fails we try to make something from the URL
		  unless ($file) {
		      my $req = $res->request;  # not always there
		      my $rurl = $req ? $req->url : $url;
		      
		      $file = ($rurl->path_segments)[-1];
		      if (!defined($file) || !length($file)) {
			  $file = "index";
			  my $suffix = media_suffix($res->content_type);
			  $file .= ".$suffix" if $suffix;
		      }
		      elsif ($rurl->scheme eq 'ftp' ||
			     $file =~ /\.t[bg]z$/   ||
			     $file =~ /\.tar(\.(Z|gz|bz2?))?$/
			  ) {
			  # leave the filename as it was
		      }
		      else {
			  my $ct = guess_media_type($file);
			  unless ($ct eq $res->content_type) {
			      # need a better suffix for this type
			      my $suffix = media_suffix($res->content_type);
			      $file .= ".$suffix" if $suffix;
			  }
		      }
		  }

		  # validate that we don't have a harmful filename now.  The server
		  # might try to trick us into doing something bad.
		  if ($file && !length($file) ||
		      $file =~ s/([^a-zA-Z0-9_\.\-\+\~])/sprintf "\\x%02x", ord($1)/ge)
		  {
		      die "Will not save <$url> as \"$file\".\nPlease override file name on the command line.\n";
		  }
		  
		  if (defined $directory) {
		      require File::Spec;
		      $file = File::Spec->catfile($directory, $file);
		  }
		  
		  # Check if the file is already present
		  if (-l $file) {
		      die "Will not save <$url> to link \"$file\".\nPlease override file name on the command line.\n";
		  }
		  elsif (-f _) {
		      die "Will not save <$url> as \"$file\" without verification.\nEither run from terminal or override file name on the command line.\n"
			  unless -t;
		      return 1 if (!$self->{overwrite});
		  }
		  elsif (-e _) {
		      die "Will not save <$url> as \"$file\".  Path exists.\n";
		  }
		  else {
		      $self->{status} = "Saving to '$file'...\n";
		  }
	      }
	      else {
		  $file = $self->{file};
	      }
	      open(FILE, ">$file") || die "Can't open $file: $!\n";
	      binmode FILE unless $self->{mode} eq 'a';
	      $self->{length} = $res->content_length;
	      $self->{flength} = fbytes($self->{length}) if defined $self->{length};
	      $self->{start_t} = time;
	      $self->{last_dur} = 0;
	  }
	  
	  print FILE $_[0] or die "Can't write to $file: $!\n";
	  $self->{size} += length($_[0]);
	  
	  if (defined $self->{length}) {
	      my $dur  = time - $self->{start_t};
	      if ($dur != $self->{last_dur}) {  # don't update too often
		  $self->{last_dur} = $dur;
		  my $perc = $self->{size} / $self->{length};
		  my $speed;
		  $speed = fbytes($self->{size}/$dur) . "/sec" if $dur > 3;
		  my $secs_left = fduration($dur/$perc - $dur);
		  $perc = int($perc*100);
		  $self->{status} = "$perc% of ".$self->{flength};
		  $self->{status} .= " (at $speed, $secs_left remaining)" if $speed;
	      }
	  }
	  else {
	      $self->{status} = "Finished. " . fbytes($self->{size}) . " received";
	  }
       });

    if (fileno(FILE)) {
	close(FILE) || die "Can't write to $file: $!\n";

	$self->{status} = "";  # clear text
	my $dur = time - $self->{start_t};
	if ($dur) {
	    my $speed = fbytes($self->{size}/$dur) . "/sec";
	}
	
	if (my $mtime = $res->last_modified) {
	    utime time, $mtime, $file;
	}
	
	if ($res->header("X-Died") || !$res->is_success) {
	    if (my $died = $res->header("X-Died")) {
		$self->{status} = $died;
	    }
	    if (-t) {
		if ($self->{autodelete}) {
		    unlink($file);
		}
		elsif ($self->{length} > $self->{size}) {
		    $self->{status} = "Aborted. Truncated file kept: " . fbytes($self->{length} - $self->{size}) . " missing";
		}
		return 1;
	    }
	    else {
		$self->{status} = "Transfer aborted, $file kept";
	    }
	}
	return 0;
    }
    return 1;
}

sub fbytes
{
    my $n = int(shift);
    if ($n >= 1024 * 1024) {
	return sprintf "%.3g MB", $n / (1024.0 * 1024);
    }
    elsif ($n >= 1024) {
	return sprintf "%.3g KB", $n / 1024.0;
    }
    else {
	return "$n bytes";
    }
}

sub fduration
{
    use integer;
    my $secs = int(shift);
    my $hours = $secs / (60*60);
    $secs -= $hours * 60*60;
    my $mins = $secs / 60;
    $secs %= 60;
    if ($hours) {
	return "$hours hours $mins minutes";
    }
    elsif ($mins >= 2) {
	return "$mins minutes";
    }
    else {
	$secs += $mins * 60;
	return "$secs seconds";
    }
}

1;
__END__

=head1 NAME

File::Download - Fetch large files from the web

=head1 DESCRIPTION

The B<lwp-download> program will save the file at I<url> to a local
file.

If I<local path> is not specified, then the current directory is
assumed.

If I<local path> is a directory, then the basename of the file to save
is picked up from the Content-Disposition header or the URL of the
response.  If the file already exists, then B<lwp-download> will
prompt before it overwrites and will fail if its standard input is not
a terminal.  This form of invocation will also fail is no acceptable
filename can be derived from the sources mentioned above.

If I<local path> is not a directory, then it is simply used as the
path to save into.

The I<lwp-download> program is implemented using the I<libwww-perl>
library.  It is better suited to down load big files than the
I<lwp-request> program because it does not store the file in memory.
Another benefit is that it will keep you updated about its progress
and that you don't have much options to worry about.

Use the C<-a> option to save the file in text (ascii) mode.  Might
make a difference on dosish systems.

=head1 EXAMPLE

Fetch the newest and greatest perl version:

 $ lwp-download http://www.perl.com/CPAN/src/latest.tar.gz
 Saving to 'latest.tar.gz'...
 11.4 MB received in 8 seconds (1.43 MB/sec)

=head1 AUTHOR

Gisle Aas <gisle@aas.no>

=cut
