#!/usr/bin/perl -w

use strict; # yes, oh yes
use utf8;
use CGI;
use LWP::Simple;
use Image::Info qw(image_info);
use MIME::Base64;
use Compress::Zlib;
use JSON;
use IO::Scalar;
use MIME::Base64;
use File::Basename;
use File::MimeInfo::Magic qw(mimetype);

local our $cgi = new CGI;
local our $action = $cgi->param('action');

if($ENV{REQUEST_METHOD} ne 'POST') { error("Illegal request.", 403); }

if ($action eq 'encode')
{
    # Read file data
    my $filehandle = $cgi->upload('file');
    my $data = undef;
    while ( <$filehandle> ) { $data .= $_;  }

    my $mime_type;
    my $is_image = is_image($filehandle);
    if ($is_image)
    {
        my $info = image_info(\$data);
        $mime_type = $info->{file_media_type};
    }
    else
    {
        my $iofh = new IO::Scalar \$data;
        $mime_type = mimetype($iofh);
    }
    
    if (!defined($mime_type)) { error('Unable to determine file mimetype.'); }
    
    my $enc = encode_base64($data, '');
    my $dataurl = "data:$mime_type;base64,$enc";
    my %reply = (   dataurl     => $dataurl,
                    size        => length($dataurl),
                    origsize    => length($data),
                    filename    => basename($filehandle),
                    image       => $is_image,
                    gzipsize    => length(Compress::Zlib::compress($dataurl))
                );
    
    reply(\%reply);
}
elsif ($action eq 'optimize') 
{    
    my $file = $cgi->param('css_file_url');
    if (!defined($file)) { error("Missing file parameter"); }
    
    my $limit = $cgi->param('size_limit');
    if (!defined($limit)) { $limit = 4096; } else { $limit *= 1024; }

    my $compress = $cgi->param('compress');
    if (!defined($compress)) { $compress = 0; }

    my %cssinfo;
    
    my $css = get($file);
    
    # Find and clean all strings contained within url()
    my (@matches) = $css =~ m/url\s?\(\s?"?'?(\s?.+\s?)'?"?\)/ig;
    foreach (@matches) { $_ = strip($_); }
    
    if ($compress eq 'on') 
    { 
        $css =~ s/\n+//g;
        $css =~ s/\t+//g;
        $css =~ s/(?m)([;:])\s+/$1/gi;
        $css =~ s/\s*}\s*/}\n/gi;
        $css =~ s/\s*{\s*/{/gi;
        $css =~ s/[ \t]*,[ \t]*/,/gi;
        $css =~ s/^\s+//;
        #$css =~ s/\s+//g;
    }
    
    $cssinfo{pre}{css_size} = length($css);
    $cssinfo{pre}{css_gzip_size} = length(Compress::Zlib::compress($css));
    $cssinfo{pre}{data_urls} = 0;
    
    my @fetch_urls;
    foreach my $url (@matches)
    {
        if ($url =~ /^data\:/) { $cssinfo{pre}{data_urls} += 1; next; }
        push(@fetch_urls, $url);
    }
    
    $cssinfo{pre}{ext_objects} = scalar(@fetch_urls);
    $cssinfo{pre}{requests} = 1 + $cssinfo{pre}{ext_objects};
    $cssinfo{pre}{img_size} = 0;
    $cssinfo{pre}{ext_size} = 0;
    $cssinfo{pre}{total_size} = 0;
    $cssinfo{dataurl_converted} = 0;
    
    my %replace_map;
    my %ext_obj_sizes;
    
    foreach my $url (@fetch_urls)
    {
        my $full_url = urljoin($file, $url);
        my $data = get($full_url);
        
        if (is_image($url) and length($data) <= $limit)
        {         
            my $info = image_info(\$data);
            my $mimetype = $info->{file_media_type};
            my $base64data = encode_base64($data, '');
            my $dataurl = "data:" . $mimetype . ";base64," . $base64data;
          
            $replace_map{$url} = $dataurl;
            $cssinfo{pre}{img_size} += length($data);
        }
        $cssinfo{pre}{ext_size} += length($data);
        $ext_obj_sizes{$url} = length($data);
    }
    $cssinfo{pre}{total_size} = $cssinfo{pre}{css_size} + $cssinfo{pre}{ext_size};
    $cssinfo{pre}{total_gzip_size} = $cssinfo{pre}{css_gzip_size} + $cssinfo{pre}{ext_size};
    $cssinfo{post}{ext_size} = $cssinfo{pre}{ext_size};
    $cssinfo{post}{img_size} = $cssinfo{pre}{img_size};
    
    foreach my $origurl (sort(keys(%replace_map)))
    {
        $css =~ s/$origurl/$replace_map{$origurl}/ig;
        $cssinfo{dataurl_converted} += 1;
        $cssinfo{post}{ext_size} -= $ext_obj_sizes{$origurl};
        if (is_image($origurl)) 
        {
            $cssinfo{post}{img_size} -= $ext_obj_sizes{$origurl};
        }
    }
    $cssinfo{post}{css_size} = length($css);
    $cssinfo{post}{data_urls} = $cssinfo{pre}{data_urls} + $cssinfo{dataurl_converted};
    $cssinfo{post}{ext_objects} = $cssinfo{pre}{ext_objects} - $cssinfo{dataurl_converted};
    $cssinfo{post}{requests} = 1 + $cssinfo{post}{ext_objects};
    $cssinfo{post}{total_size} = $cssinfo{post}{css_size} + $cssinfo{post}{ext_size};
    $cssinfo{post}{css_gzip_size} = length(Compress::Zlib::compress($css));
    $cssinfo{post}{total_gzip_size} = $cssinfo{post}{css_gzip_size} + $cssinfo{post}{ext_size};
    $cssinfo{css_output} = $css;
    
    # foreach (keys(%cssinfo)) {
    #     print $_ . ' : ' . $cssinfo{$_} . "\n";
    # }
    # 
    # print $css;
    
    reply(\%cssinfo);
}

sub reply
{
    my ($hashref, $status) = @_;
    binmode(STDOUT, ":utf8");
    if (!defined($status)) { $status = '200 OK'; }
    print "Status: $status\n";
    print STDOUT "Content-Type: application/json\n\n";
    print STDOUT encode_json($hashref);
    exit(0);
}

sub error
{
    my ($errmsg, $status) = @_;
    if (!defined($status)) { $status = '500'; }
    my %reply = ( error => $errmsg );
    reply(\%reply, $status);
    exit(1);
}

sub is_image
{
    my ($str) = @_;
    if ($str =~ m/\.jpg$/i or $str =~ m/\.png$/i or $str =~ m/\.gif$/i or $str =~ m/\.jpeg$/i) { return 1; }
    return 0;
}

sub strip
{
    my ($s) = @_;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    $s =~ s/^'//;
    $s =~ s/'$//;
    $s =~ s/^"//;
    $s =~ s/"$//;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub urljoin
{
    my ($a, $b) = @_;
    my $result;
    
    if (!$a) { return $b; }
    if (!$b) { return $a; }
    
    # latter full url overrides prior
    if ($b =~ m/^http/) { return $b; }
    
    my ($a_protocol) = $a =~ m/(https?)\:\/\//;
    my ($b_protocol) = $b =~ m/(https?)\:\/\//;
    
    $a =~ s/$a_protocol\:\/\///i;
    
    my ($domain, @path_elements) = split(/\//, $a);
    
    if ($b =~ m/^\//) 
    {
        $result = $a_protocol . '://' . $domain . $b;
        return $result;
    }
        
    pop(@path_elements);
    push(@path_elements, $b);
    
    $result = $a_protocol . '://' . $domain;
    foreach (@path_elements)
    {
        $result .= '/' . $_;
    }
    
    return $result;
}






